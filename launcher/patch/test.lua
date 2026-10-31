--[[
Offline tests for 2-koreader-home.lua. The patch is loaded against stand-ins
for KOReader's Device and MenuSorter, then Device:exit() and a menu build are
run. Like the real MenuSorter:sort, the stand-in removes each item from
menu_items as it places it in the menu (relabelling menu_items afterwards had
no effect on the device). A fake JNIEnv models the raw JNI functions the
patch calls; any of them can be made to throw (or, for GetStringUTFChars, fail
its allocation). The tests fail if the patch makes a JNI call that is not
allowed while an exception is pending, leaves an exception pending, raises
(KOReader is exiting, or building a menu), starts Home or relabels Exit when
it should not, or skips KOReader's own exit.

Usage: luajit launcher/patch/test.lua   (from the repo root; `make check` runs it)
--]]

local ffi = require("ffi")

local PATCH = "launcher/patch/2-koreader-home.lua"

local SAFE_WHILE_PENDING = {
    ExceptionCheck = true, ExceptionOccurred = true, ExceptionClear = true,
    DeleteLocalRef = true, ReleaseStringUTFChars = true,
}

local throw_at       -- "<function>" or "<function>:<name>" that should throw
local pending        -- the pending exception, if any
local violations     -- JNI calls made while an exception was pending
local default_home   -- package the fake PackageManager resolves HOME to, or nil
local started        -- the intent passed to startActivity, if any
local keep = {}      -- keeps C strings alive for ffi.string

-- Records the call before touching its arguments: after a missed exception
-- check, an argument can be the nil a failed call returned.
local function refName(ref) return ref and ref.name or "<nil>" end

local function enter(fn, detail)
    if pending and not SAFE_WHILE_PENDING[fn] then
        table.insert(violations, detail and (fn .. ":" .. detail) or fn)
    end
    if throw_at == fn or (detail and throw_at == fn .. ":" .. detail) then
        pending = { text = "thrown at " .. throw_at }
        return true
    end
    return false
end

local context = { kind = "activity" }

local env = {}
env[0] = {
    ExceptionCheck = function() return pending and 1 or 0 end,
    ExceptionOccurred = function() return pending end,
    ExceptionClear = function() pending = nil end,
    DeleteLocalRef = function() enter("DeleteLocalRef") end,
    NewStringUTF = function(_, s)
        if enter("NewStringUTF") then return nil end
        return { str = s }
    end,
    FindClass = function(_, name)
        if enter("FindClass", name) then return nil end
        return { name = name }
    end,
    GetObjectClass = function(_, obj)
        if enter("GetObjectClass") then return nil end
        assert(obj, "GetObjectClass on null")
        return { name = obj.kind }
    end,
    GetMethodID = function(_, _, name)
        if enter("GetMethodID", name) then return nil end
        return { name = name }
    end,
    GetFieldID = function(_, _, name)
        if enter("GetFieldID", name) then return nil end
        return { name = name }
    end,
    NewObject = function(_, cls, _, action)
        if enter("NewObject") then return nil end
        assert(cls.name == "android/content/Intent", "constructed " .. tostring(cls.name))
        return { kind = "intent", action = action.str, categories = {}, flags = 0 }
    end,
    CallObjectMethod = function(_, obj, mid, a, b)
        if enter("CallObjectMethod", refName(mid)) then return nil end
        if mid.name == "addCategory" then
            table.insert(obj.categories, a.str)
            return obj
        elseif mid.name == "addFlags" then
            obj.flags = bit.bor(obj.flags, tonumber(a))
            return obj
        elseif mid.name == "getPackageManager" then
            return { kind = "pm" }
        elseif mid.name == "resolveActivity" then
            assert(tonumber(b) == 0x10000, "resolveActivity without MATCH_DEFAULT_ONLY")
            if not default_home then return nil end
            return { kind = "resolveinfo", activityInfo = { kind = "activityinfo", packageName = default_home } }
        end
        error("unexpected method " .. mid.name)
    end,
    GetObjectField = function(_, obj, fid)
        if enter("GetObjectField", refName(fid)) then return nil end
        local value = obj[fid.name]
        if type(value) == "string" then return { str = value } end
        return value
    end,
    CallVoidMethod = function(_, obj, mid, intent)
        if enter("CallVoidMethod", refName(mid)) then return end
        assert(mid.name == "startActivity" and obj == context, "unexpected void call " .. mid.name)
        started = intent
    end,
    GetStringUTFChars = function(_, s)
        if enter("GetStringUTFChars") then return nil end -- allocation failure
        local buf = ffi.new("char[?]", #s.str + 1, s.str)
        keep[#keep + 1] = buf
        return buf
    end,
    GetStringUTFLength = function(_, s) return #s.str end,
    ReleaseStringUTFChars = function() enter("ReleaseStringUTFChars") end,
}

-- The fake jni object has no call*Method/to_string helpers, so any use of
-- KOReader's unchecked bridge fails.
local jni = { env = env }
function jni:context(_, fn) return fn(self) end

local is_android
local logged
local exited          -- KOReader's own Device:exit ran
local Device, MenuSorter
local function load(name, value) package.loaded[name] = value end

-- Stand-in for MenuSorter: like the real sort, it moves items into the menu
-- and removes them from item_table.
local function newMenuSorter()
    local sorter = {}
    function sorter:mergeAndSort(_, item_table)
        local menu = { exit_menu = item_table.exit_menu }
        item_table.exit_menu = nil
        return menu
    end
    return sorter
end

local function loadPatch()
    exited = false
    Device = {
        isAndroid = function() return is_android end,
        exit = function(self) assert(self == Device); exited = true end,
    }
    MenuSorter = newMenuSorter()
    load("device", Device)
    load("ui/menusorter", MenuSorter)
    load("android", { jni = jni, app = { activity = { vm = {}, clazz = context } } })
    load("gettext", function(text) return text end)
    local function log(...) logged[#logged + 1] = table.concat({ ... }, " ") end
    load("logger", { info = log, warn = log, dbg = log })
    dofile(PATCH)
end

-- Builds a menu the way FileManagerMenu/ReaderMenu do: menu_items with the
-- common exit table's "Exit" leaf (Android), then MenuSorter:mergeAndSort.
local function exitLabel(prefix)
    local menu_items = { exit_menu = { text = "Exit" } }
    return MenuSorter:mergeAndSort(prefix, menu_items, {}).exit_menu.text
end

-- Tests ------------------------------------------------------------------------

local passed, failed = 0, 0
local function test(name, fn)
    throw_at, pending, violations, started, logged = nil, nil, {}, nil, {}
    default_home, is_android = "dev.nookkoreader.launcher", true
    local ok, err = pcall(fn)
    if ok and #violations > 0 then
        ok, err = false, "JNI calls with an exception pending: " .. table.concat(violations, ", ")
    end
    if ok and pending then ok, err = false, "exception left pending" end
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end

test("exit starts Home after KOReader's own exit when KOReader Home is the default", function()
    loadPatch()
    Device:exit()
    assert(exited, "KOReader's exit did not run")
    assert(started, "Home was not started")
    assert(started.action == "android.intent.action.MAIN", "action " .. tostring(started.action))
    assert(#started.categories == 1 and started.categories[1] == "android.intent.category.HOME",
        "HOME must be the only category")
    assert(bit.band(started.flags, 0x10000000) ~= 0, "missing FLAG_ACTIVITY_NEW_TASK")
    assert(started.component == nil, "the intent must stay implicit")
end)

test("Home is started only after KOReader's own exit", function()
    loadPatch()
    local orig = env[0].CallVoidMethod
    env[0].CallVoidMethod = function(...)
        assert(exited, "Home started before KOReader's exit")
        return orig(...)
    end
    local ok, err = pcall(Device.exit, Device)
    env[0].CallVoidMethod = orig
    assert(ok, err)
    assert(started, "Home was not started")
end)

test("other menus are left alone", function()
    loadPatch()
    local items = { exit_menu = { text = "Exit" } }
    MenuSorter:mergeAndSort("dispatcher", items, {})
    assert(not started, "started Home")
    assert(#logged == 0, "checked the default Home for an unrelated menu")
end)

test("both menus label Exit as Restart KOReader", function()
    loadPatch()
    assert(exitLabel("filemanager") == "Restart KOReader", "file manager: " .. exitLabel("filemanager"))
    assert(exitLabel("reader") == "Restart KOReader", "reader: " .. exitLabel("reader"))
    assert(not started, "building a menu started Home")
end)

for _, case in ipairs({
    { "another launcher is the default", "app.olauncher" },
    { "no default Home is chosen (chooser)", "android" },
    { "HOME resolves to nothing", false },
}) do
    test("exit and label unchanged when " .. case[1], function()
        default_home = case[2] or nil
        loadPatch()
        Device:exit()
        assert(exited, "KOReader's exit did not run")
        assert(not started, "started Home")
        assert(exitLabel("filemanager") == "Exit" and exitLabel("reader") == "Exit", "relabelled Exit")
    end)
end

test("does nothing outside Android", function()
    is_android = false
    loadPatch()
    Device:exit()
    assert(exited and not started and #logged == 0, "ran outside Android")
    assert(exitLabel("filemanager") == "Exit", "relabelled Exit")
end)

-- Make every raw JNI step throw in turn: exit must still run KOReader's own
-- exit, start nothing, and log; menus must keep "Exit" and not raise.
local steps = {
    "FindClass:android/content/Intent", "GetMethodID:<init>", "NewStringUTF", "NewObject",
    "GetObjectClass", "GetMethodID:addCategory", "CallObjectMethod:addCategory",
    "GetMethodID:addFlags", "CallObjectMethod:addFlags",
    "GetMethodID:getPackageManager", "CallObjectMethod:getPackageManager",
    "GetMethodID:resolveActivity", "CallObjectMethod:resolveActivity",
    "GetFieldID:activityInfo", "GetObjectField:activityInfo",
    "GetFieldID:packageName", "GetObjectField:packageName",
    "GetStringUTFChars",
    "GetMethodID:startActivity", "CallVoidMethod:startActivity",
}
for _, step in ipairs(steps) do
    test("exit: failure at " .. step .. " stops cleanly", function()
        throw_at = step
        loadPatch()
        local ok, err = pcall(Device.exit, Device)
        assert(ok, "exit raised: " .. tostring(err))
        assert(exited, "KOReader's exit did not run")
        assert(not started, "started Home after a failure")
        assert(#logged == 1 and logged[1]:find("could not return to Home", 1, true),
            "failure not logged: " .. table.concat(logged, " | "))
    end)
    if not step:find("startActivity", 1, true) then
        test("menu: failure at " .. step .. " keeps Exit", function()
            throw_at = step
            loadPatch()
            local ok, label = pcall(exitLabel, "reader")
            assert(ok, "menu raised: " .. tostring(label))
            assert(label == "Exit", "label " .. tostring(label))
            assert(#logged == 1 and logged[1]:find("could not check the default Home", 1, true),
                "failure not logged: " .. table.concat(logged, " | "))
        end)
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
