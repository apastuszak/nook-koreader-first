--[[--
KOReader Home: make Exit restart KOReader.

While KOReader Home (dev.nookkoreader.launcher) is the default Home app:

- Exit returns to Home, which reopens KOReader. KOReader's Exit on Android
  finishes its activity and then ends its process at once. Android handles that
  like a dying app and shows whatever app is open behind KOReader (e.g. a
  launcher opened from the recovery screen), even when KOReader was opened from
  Home. This patch wraps Device:exit and, after it has asked Android to finish
  the activity (just before the process ends), starts the HOME intent.
- The Exit menu item is labelled "Restart KOReader", KOReader's own (translated)
  label for that action on other devices.

With any other default Home app, Exit is left exactly as it is.

Install: copy this file to koreader/patches/ on the device. The "2-" prefix
runs it once KOReader's UI is ready, before the file manager or reader opens.
License: AGPL-3.0-or-later.
--]]

local Device = require("device")
if not Device:isAndroid() then return end

local ffi = require("ffi")
local logger = require("logger")
local _ = require("gettext")

local LAUNCHER = "dev.nookkoreader.launcher"
local FLAG_ACTIVITY_NEW_TASK = 0x10000000
local MATCH_DEFAULT_ONLY = 0x10000

-- Raw JNI with a check after every call that can throw, for the same reason as
-- plugin/nookwifi.koplugin/nookwifihelper.lua: KOReader's jni:call*Method and
-- jni:to_string chain several calls without checking for exceptions.
local function takeException(env)
    if env[0].ExceptionCheck(env) == 0 then return false end
    env[0].ExceptionClear(env)
    return true
end

local function checked(env, value)
    if takeException(env) then error("Java exception", 0) end
    return value
end

local function newString(env, text)
    return checked(env, env[0].NewStringUTF(env, text))
end

local function methodId(env, obj, name, sig)
    local cls = checked(env, env[0].GetObjectClass(env, obj))
    local mid = checked(env, env[0].GetMethodID(env, cls, name, sig))
    env[0].DeleteLocalRef(env, cls)
    return mid
end

local function callObject(env, obj, name, sig, ...)
    local mid = methodId(env, obj, name, sig)
    return checked(env, env[0].CallObjectMethod(env, obj, mid, ...))
end

local function callVoid(env, obj, name, sig, ...)
    local mid = methodId(env, obj, name, sig)
    env[0].CallVoidMethod(env, obj, mid, ...)
    checked(env)
end

local function objectField(env, obj, name, sig)
    local cls = checked(env, env[0].GetObjectClass(env, obj))
    local fid = checked(env, env[0].GetFieldID(env, cls, name, sig))
    env[0].DeleteLocalRef(env, cls)
    return checked(env, env[0].GetObjectField(env, obj, fid))
end

local function toLuaString(env, jstr)
    local chars = env[0].GetStringUTFChars(env, jstr, nil)
    if chars == nil then
        checked(env)
        error("could not read a Java string", 0)
    end
    local text = ffi.string(chars, env[0].GetStringUTFLength(env, jstr))
    env[0].ReleaseStringUTFChars(env, jstr, chars)
    return text
end

-- The HOME intent. HOME must be the only category, and the intent must stay
-- implicit, for Android to start the launcher as Home rather than as an
-- ordinary activity.
local function homeIntent(env)
    local cls = checked(env, env[0].FindClass(env, "android/content/Intent"))
    local ctor = checked(env, env[0].GetMethodID(env, cls, "<init>", "(Ljava/lang/String;)V"))
    local intent = checked(env, env[0].NewObject(env, cls, ctor, newString(env, "android.intent.action.MAIN")))
    env[0].DeleteLocalRef(env, cls)
    callObject(env, intent, "addCategory", "(Ljava/lang/String;)Landroid/content/Intent;",
        newString(env, "android.intent.category.HOME"))
    callObject(env, intent, "addFlags", "(I)Landroid/content/Intent;", ffi.cast("int32_t", FLAG_ACTIVITY_NEW_TASK))
    return intent
end

-- True if KOReader Home is the default Home app. With no default chosen,
-- Android resolves to its chooser, which is not ours.
local function isDefaultHome(env, context, intent)
    local pm = callObject(env, context, "getPackageManager", "()Landroid/content/pm/PackageManager;")
    local home = callObject(env, pm, "resolveActivity",
        "(Landroid/content/Intent;I)Landroid/content/pm/ResolveInfo;", intent, ffi.cast("int32_t", MATCH_DEFAULT_ONLY))
    if home == nil then return false end
    local info = objectField(env, home, "activityInfo", "Landroid/content/pm/ActivityInfo;")
    if info == nil then return false end
    local pkg = objectField(env, info, "packageName", "Ljava/lang/String;")
    return pkg ~= nil and toLuaString(env, pkg) == LAUNCHER
end

-- Runs fn(env, context) in a JNI context. Returns its result, or nil and an
-- error text; never raises, and never leaves an exception pending.
local function withJni(fn)
    local ok, result, err = pcall(function()
        local android = require("android")
        return android.jni:context(android.app.activity.vm, function(jni)
            local call_ok, value = pcall(fn, jni.env, android.app.activity.clazz)
            if call_ok then return value end
            takeException(jni.env)
            return nil, value
        end)
    end)
    if not ok then return nil, result end
    return result, err
end

local function launcherIsDefault()
    local result, err = withJni(function(env, context)
        return isDefaultHome(env, context, homeIntent(env))
    end)
    if err then logger.warn("KOReaderHome: could not check the default Home app:", err) end
    return result == true
end

-- Exit: after KOReader has asked Android to finish its activity, go Home.
local orig_exit = Device.exit
Device.exit = function(self, ...)
    orig_exit(self, ...)
    local started, err = withJni(function(env, context)
        local intent = homeIntent(env)
        if not isDefaultHome(env, context, intent) then return false end
        callVoid(env, context, "startActivity", "(Landroid/content/Intent;)V", intent)
        return true
    end)
    if started then
        logger.info("KOReaderHome: returning to Home on exit")
    elseif err then
        logger.warn("KOReaderHome: could not return to Home on exit:", err)
    end
end

-- Menu label. FileManagerMenu and ReaderMenu rebuild menu_items from KOReader's
-- common exit table, then pass them to MenuSorter:mergeAndSort ("filemanager" or
-- "reader"), which moves each item into the menu and removes it from menu_items.
-- So the label must change before sorting; afterwards exit_menu is gone.
local MenuSorter = require("ui/menusorter")
local orig_merge = MenuSorter.mergeAndSort
MenuSorter.mergeAndSort = function(self, config_prefix, item_table, ...)
    local item = (config_prefix == "filemanager" or config_prefix == "reader")
        and type(item_table) == "table" and item_table.exit_menu
    if item and launcherIsDefault() then
        item.text = _("Restart KOReader")
    end
    return orig_merge(self, config_prefix, item_table, ...)
end
