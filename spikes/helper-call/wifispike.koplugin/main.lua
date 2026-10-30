--[[--
Stage 0 Test 2 (throwaway): calls the helper spike's ContentProvider through
ContentResolver.call() over JNI and reports what came back. Every line of the
report is also logged with the prefix "WifiSpike2" for `adb logcat`.
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")

local AUTHORITY = "dev.nookwifi.helperspike"
local MISSING_AUTHORITY = "dev.nookwifi.doesnotexist"

local WifiSpike = WidgetContainer:extend{
    name = "wifispike",
    is_doc_only = false,
}

function WifiSpike:init()
    if not Device:isAndroid() then return end
    self.ui.menu:registerToMainMenu(self)
end

function WifiSpike:addToMainMenu(menu_items)
    menu_items.wifi_spike = {
        text = "Wi-Fi helper spike (Test 2)",
        sorting_hint = "more_tools",
        callback = function() self:runAll() end,
    }
end

-- KOReader's JNI helpers never check for exceptions, and a pending exception
-- makes the next JNI call undefined, so check after every call that can throw.
-- Returns the exception as a string (and clears it), or nil.
local function takeException(jni)
    local env = jni.env
    if env[0].ExceptionCheck(env) == 0 then return nil end
    local exc = env[0].ExceptionOccurred(env)
    env[0].ExceptionClear(env)
    local s = jni:callObjectMethod(exc, "toString", "()Ljava/lang/String;")
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionClear(env)
        return "Java exception (toString failed)"
    end
    return s ~= nil and jni:to_string(s) or "Java exception"
end

-- Calls ContentResolver.call(content://<authority>, method, arg, extras).
-- Returns the reply's "json" string, or nil and an error string. Never raises
-- inside the JNI context, so the thread is always detached.
local function callHelper(authority, method, arg, extras)
    local android = require("android")
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local uri = jni:callStaticObjectMethod("android/net/Uri", "parse",
            "(Ljava/lang/String;)Landroid/net/Uri;",
            env[0].NewStringUTF(env, "content://" .. authority))
        local err = takeException(jni)
        if err then return nil, err end

        local bundle_in
        if extras then
            local cls = env[0].FindClass(env, "android/os/Bundle")
            bundle_in = env[0].NewObject(env, cls, env[0].GetMethodID(env, cls, "<init>", "()V"))
            for k, v in pairs(extras) do
                jni:callVoidMethod(bundle_in, "putString", "(Ljava/lang/String;Ljava/lang/String;)V",
                    env[0].NewStringUTF(env, k), env[0].NewStringUTF(env, v))
            end
            err = takeException(jni)
            if err then return nil, err end
        end

        local resolver = jni:callObjectMethod(android.app.activity.clazz,
            "getContentResolver", "()Landroid/content/ContentResolver;")
        local reply = jni:callObjectMethod(resolver, "call",
            "(Landroid/net/Uri;Ljava/lang/String;Ljava/lang/String;Landroid/os/Bundle;)Landroid/os/Bundle;",
            uri, env[0].NewStringUTF(env, method),
            arg and env[0].NewStringUTF(env, arg) or nil, bundle_in)
        err = takeException(jni)
        if err then return nil, err end
        if reply == nil then return nil, "helper returned null" end

        local json_str = jni:callObjectMethod(reply, "getString",
            "(Ljava/lang/String;)Ljava/lang/String;", env[0].NewStringUTF(env, "json"))
        err = takeException(jni)
        if err then return nil, err end
        if json_str == nil then return nil, "reply has no json" end
        return jni:to_string(json_str)
    end)
end

-- Runs one call, timing it. Returns decoded reply (or nil), raw/error text, ms.
local function timedCall(authority, method, arg, extras)
    local start = time.monotonic()
    local ok, raw, err = pcall(callHelper, authority, method, arg, extras)
    local ms = time.to_ms(time.since(start))
    if not ok then return nil, "Lua error: " .. tostring(raw), ms end
    if not raw then return nil, err, ms end
    local decoded_ok, decoded = pcall(JSON.decode, raw)
    if not decoded_ok then return nil, "bad JSON: " .. raw, ms end
    return decoded, raw, ms
end

function WifiSpike:runAll()
    local lines = {}
    local function report(fmt, ...)
        local line = string.format(fmt, ...)
        table.insert(lines, line)
        logger.info("WifiSpike2", line)
    end

    local reply, text, ms

    reply, text, ms = timedCall(AUTHORITY, "ping")
    report("1 ping (first call): %s [%d ms] %s", reply and "OK" or "FAIL", ms, text)

    local times = {}
    for _ = 1, 5 do
        reply, text, ms = timedCall(AUTHORITY, "ping")
        table.insert(times, reply and ms or -1)
    end
    report("2 ping x5 warm ms: %s", table.concat(times, ", "))

    local bmp = "Caf\u{E9} \u{2713} \u{65E5}\u{672C} 123"
    reply, text, ms = timedCall(AUTHORITY, "echo", bmp, { key = "extras-value \u{2713}" })
    report("3 echo BMP: %s, extras %s [%d ms] %s",
        reply and reply.echo == bmp and "MATCH" or "MISMATCH",
        reply and reply.extrasKey == "extras-value \u{2713}" and "MATCH" or "MISMATCH",
        ms, text)

    reply, text, ms = timedCall(AUTHORITY, "wifiState")
    report("4 wifiState: %s [%d ms] %s", reply and "OK" or "FAIL", ms, text)

    reply, text, ms = timedCall(AUTHORITY, "noSuchMethod")
    report("5 unknown method (expect ok=false): %s [%d ms] %s",
        reply and reply.ok == false and "OK" or "UNEXPECTED", ms, text)

    reply, text, ms = timedCall(AUTHORITY, "fail")
    report("6 helper throws (expect exception): %s [%d ms] %s",
        reply == nil and "OK" or "UNEXPECTED", ms, text)
    reply, text = timedCall(AUTHORITY, "ping")
    report("6b ping after exception: %s", reply and "OK" or ("FAIL " .. tostring(text)))

    reply, text, ms = timedCall(MISSING_AUTHORITY, "ping")
    report("7 missing helper (expect exception): %s [%d ms] %s",
        reply == nil and "OK" or "UNEXPECTED", ms, text)
    reply, text = timedCall(AUTHORITY, "ping")
    report("7b ping after missing helper: %s", reply and "OK" or ("FAIL " .. tostring(text)))

    -- Last, in case non-BMP text misbehaves in NewStringUTF/GetStringUTFChars.
    local emoji = "Wi-Fi \u{1F4F6} test"
    reply, text, ms = timedCall(AUTHORITY, "echo", emoji)
    report("8 echo emoji: %s [%d ms] %s",
        reply and reply.echo == emoji and "MATCH" or "MISMATCH", ms, text)

    report("done")
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n\n") })
end

return WifiSpike
