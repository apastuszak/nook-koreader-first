--[[--
JNI client for the Nook Wi-Fi Helper app.

Calls ContentResolver.call(content://dev.nookwifi.helper, method, arg, extras)
and decodes the reply's "json" string. See helper/.../HelperProvider.java for
the protocol.

@module nookwifihelper
--]]

local JSON = require("json")
local ffi = require("ffi")
local logger = require("logger")

local AUTHORITY = "dev.nookwifi.helper"

local Helper = {
    PROTOCOL = 1,
}

-- This client calls raw JNI functions instead of KOReader's jni:call*Method
-- helpers and jni:to_string, because those chain several JNI calls (class
-- lookup, method lookup, call, string conversion) without checking for
-- exceptions or failed allocations in between. Calling JNI with an exception
-- pending is undefined behavior, so every call that can throw is checked.

-- Returns the pending exception's text and clears it, or nil if none. Describing
-- the exception uses JNI too; anything that fails along the way is cleared.
local function takeException(env)
    if env[0].ExceptionCheck(env) == 0 then return nil end
    local exc = env[0].ExceptionOccurred(env)
    env[0].ExceptionClear(env)
    local text = "Java exception"
    local cls = env[0].GetObjectClass(env, exc)
    if env[0].ExceptionCheck(env) == 0 then
        local mid = env[0].GetMethodID(env, cls, "toString", "()Ljava/lang/String;")
        if env[0].ExceptionCheck(env) == 0 then
            local str = env[0].CallObjectMethod(env, exc, mid)
            if env[0].ExceptionCheck(env) == 0 and str ~= nil then
                local chars = env[0].GetStringUTFChars(env, str, nil)
                if chars ~= nil then
                    text = ffi.string(chars, env[0].GetStringUTFLength(env, str))
                    env[0].ReleaseStringUTFChars(env, str, chars)
                end
            end
        end
    end
    env[0].ExceptionClear(env)
    return text
end

-- Checked JNI primitives. Each raises a Lua error with the exception text, so
-- rawCall can bail out; rawCall catches it inside the JNI context.
local function checked(env, value)
    local err = takeException(env)
    if err then error(err, 0) end
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

local function callStaticObject(env, class_name, name, sig, ...)
    local cls = checked(env, env[0].FindClass(env, class_name))
    local mid = checked(env, env[0].GetStaticMethodID(env, cls, name, sig))
    local result = checked(env, env[0].CallStaticObjectMethod(env, cls, mid, ...))
    env[0].DeleteLocalRef(env, cls)
    return result
end

local function newObject(env, class_name)
    local cls = checked(env, env[0].FindClass(env, class_name))
    local ctor = checked(env, env[0].GetMethodID(env, cls, "<init>", "()V"))
    local obj = checked(env, env[0].NewObject(env, cls, ctor))
    env[0].DeleteLocalRef(env, cls)
    return obj
end

local function toLuaString(env, jstr)
    local chars = env[0].GetStringUTFChars(env, jstr, nil)
    if chars == nil then
        checked(env) -- raises the pending OutOfMemoryError, if any
        error("could not read a Java string", 0)
    end
    local text = ffi.string(chars, env[0].GetStringUTFLength(env, jstr))
    env[0].ReleaseStringUTFChars(env, jstr, chars)
    return text
end

-- Does the actual call. Raises on any failure; local references are freed when
-- KOReader detaches the thread at the end of the JNI context.
local function callInContext(env, context, method, arg, extras)
    local uri = callStaticObject(env, "android/net/Uri", "parse",
        "(Ljava/lang/String;)Landroid/net/Uri;", newString(env, "content://" .. AUTHORITY))

    local bundle_in
    if extras then
        bundle_in = newObject(env, "android/os/Bundle")
        for k, v in pairs(extras) do
            callVoid(env, bundle_in, "putString", "(Ljava/lang/String;Ljava/lang/String;)V",
                newString(env, k), newString(env, v))
        end
    end

    local jmethod = newString(env, method)
    local jarg = arg and newString(env, arg) or nil
    local resolver = callObject(env, context, "getContentResolver", "()Landroid/content/ContentResolver;")
    local reply = callObject(env, resolver, "call",
        "(Landroid/net/Uri;Ljava/lang/String;Ljava/lang/String;Landroid/os/Bundle;)Landroid/os/Bundle;",
        uri, jmethod, jarg, bundle_in)
    if reply == nil then error("helper returned null", 0) end

    local json_str = callObject(env, reply, "getString", "(Ljava/lang/String;)Ljava/lang/String;",
        newString(env, "json"))
    if json_str == nil then error("reply has no json", 0) end
    return toLuaString(env, json_str)
end

-- Returns the reply's raw JSON string, or nil and an error string. Errors are
-- caught inside the JNI context, so the thread is always detached.
local function rawCall(method, arg, extras)
    local android = require("android")
    return android.jni:context(android.app.activity.vm, function(jni)
        local ok, result = pcall(callInContext, jni.env, android.app.activity.clazz, method, arg, extras)
        if ok then return result end
        -- A Lua error (not a Java one) can leave an exception pending; never leak it.
        takeException(jni.env)
        return nil, result
    end)
end

--[[--
Calls a helper method.

@string method helper method name
@string[opt] arg string argument
@tparam[opt] table extras string keys to string values, passed as a Bundle
@treturn table|nil decoded reply (has `ok`; on failure also `error`)
@treturn string|nil error code when the call itself failed:
  "helper_not_installed", "protocol_mismatch", "bad_reply", or "jni_error"
--]]
function Helper.call(method, arg, extras)
    local ok, raw, err = pcall(rawCall, method, arg, extras)
    if not ok then
        logger.warn("NookWifi: Lua error calling", method, raw)
        return nil, "jni_error"
    end
    if not raw then
        logger.warn("NookWifi:", method, "failed:", err)
        if err and err:find("Unknown URI", 1, true) then
            return nil, "helper_not_installed"
        end
        return nil, "jni_error"
    end
    local decoded_ok, reply = pcall(JSON.decode, raw)
    if not decoded_ok or type(reply) ~= "table" then
        logger.warn("NookWifi: bad reply to", method)
        return nil, "bad_reply"
    end
    if reply.protocol ~= Helper.PROTOCOL then
        logger.warn("NookWifi: helper protocol", reply.protocol, "expected", Helper.PROTOCOL)
        return nil, "protocol_mismatch"
    end
    return reply
end

return Helper
