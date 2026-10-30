--[[--
JNI client for the Nook Wi-Fi Helper app.

Calls ContentResolver.call(content://dev.nookwifi.helper, method, arg, extras)
and decodes the reply's "json" string. See helper/.../HelperProvider.java for
the protocol.

@module nookwifihelper
--]]

local JSON = require("json")
local logger = require("logger")

local AUTHORITY = "dev.nookwifi.helper"

local Helper = {
    PROTOCOL = 1,
}

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

-- Returns the reply's raw JSON string, or nil and an error string. Never
-- raises inside the JNI context, so the thread is always detached. Every JNI
-- call that can throw is followed by takeException, because making another JNI
-- call with an exception pending is undefined behavior.
local function rawCall(method, arg, extras)
    local android = require("android")
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        -- Wraps a JNI call: returns its result, or nil and the exception text.
        local function checked(value)
            local err = takeException(jni)
            if err then return nil, err end
            return value
        end
        local function jstring(text)
            return checked(env[0].NewStringUTF(env, text))
        end

        local uri_text, err = jstring("content://" .. AUTHORITY)
        if err then return nil, err end
        local uri
        uri, err = checked(jni:callStaticObjectMethod("android/net/Uri", "parse",
            "(Ljava/lang/String;)Landroid/net/Uri;", uri_text))
        if err then return nil, err end

        local bundle_in
        if extras then
            local cls
            cls, err = checked(env[0].FindClass(env, "android/os/Bundle"))
            if err then return nil, err end
            local ctor
            ctor, err = checked(env[0].GetMethodID(env, cls, "<init>", "()V"))
            if err then return nil, err end
            bundle_in, err = checked(env[0].NewObject(env, cls, ctor))
            if err then return nil, err end
            for k, v in pairs(extras) do
                local jk, jv
                jk, err = jstring(k)
                if err then return nil, err end
                jv, err = jstring(v)
                if err then return nil, err end
                jni:callVoidMethod(bundle_in, "putString", "(Ljava/lang/String;Ljava/lang/String;)V", jk, jv)
                err = takeException(jni)
                if err then return nil, err end
            end
        end

        local jmethod, jarg, resolver, reply, jkey, json_str
        jmethod, err = jstring(method)
        if err then return nil, err end
        if arg then
            jarg, err = jstring(arg)
            if err then return nil, err end
        end
        resolver, err = checked(jni:callObjectMethod(android.app.activity.clazz,
            "getContentResolver", "()Landroid/content/ContentResolver;"))
        if err then return nil, err end
        reply, err = checked(jni:callObjectMethod(resolver, "call",
            "(Landroid/net/Uri;Ljava/lang/String;Ljava/lang/String;Landroid/os/Bundle;)Landroid/os/Bundle;",
            uri, jmethod, jarg, bundle_in))
        if err then return nil, err end
        if reply == nil then return nil, "helper returned null" end

        jkey, err = jstring("json")
        if err then return nil, err end
        json_str, err = checked(jni:callObjectMethod(reply, "getString",
            "(Ljava/lang/String;)Ljava/lang/String;", jkey))
        if err then return nil, err end
        if json_str == nil then return nil, "reply has no json" end
        return jni:to_string(json_str)
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
