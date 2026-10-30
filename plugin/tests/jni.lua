--[[
Offline tests for nookwifihelper.lua (the JNI client). A fake JNIEnv models the
raw JNI functions the client calls. Any of them can be made to throw (or, for
GetStringUTFChars, fail its allocation); the tests fail if the client makes a
JNI call that is not allowed while an exception is pending, which is undefined
behavior on Android. The fake jni object has no call*Method/to_string helpers,
so any use of KOReader's unchecked bridge fails too.

Usage: luajit plugin/tests/jni.lua   (from the repo root; `make check` runs it)
--]]

local ffi = require("ffi")

package.path = "plugin/nookwifi.koplugin/?.lua;" .. package.path

package.preload["logger"] = function()
    local noop = function() end
    return { info = noop, warn = noop, dbg = noop }
end
package.preload["json"] = function()
    -- Just enough JSON for these replies.
    return {
        decode = function(s)
            local t = {}
            for k, v in s:gmatch('"(%w+)":([^,}]+)') do
                if v == "true" then t[k] = true
                elseif v == "false" then t[k] = false
                elseif tonumber(v) then t[k] = tonumber(v)
                else t[k] = v:gsub('^"(.*)"$', "%1") end
            end
            return t
        end,
    }
end

-- Fake JNIEnv -------------------------------------------------------------------

-- JNI functions the spec allows while an exception is pending.
local SAFE_WHILE_PENDING = {
    ExceptionCheck = true, ExceptionOccurred = true, ExceptionClear = true,
    DeleteLocalRef = true, ReleaseStringUTFChars = true,
}

local throw_at       -- "<function>" or "<function>:<method name>" that should throw
local pending        -- the pending exception, if any
local violations     -- JNI calls made while an exception was pending
local helper_reply   -- JSON the fake ContentResolver.call returns
local sent_extras    -- extras the client put in the Bundle
local keep = {}      -- keeps C strings alive for ffi.string

local function enter(fn, detail)
    if pending and not SAFE_WHILE_PENDING[fn] then
        table.insert(violations, detail and (fn .. ":" .. detail) or fn)
    end
    if throw_at == fn or (detail and throw_at == fn .. ":" .. detail) then
        pending = { class = { name = "java/lang/RuntimeException" }, text = "thrown at " .. throw_at }
        return true
    end
    return false
end

local function jstr(s) return { str = s } end

local env = {}
env[0] = {
    ExceptionCheck = function() return pending and 1 or 0 end,
    ExceptionOccurred = function() return pending end,
    ExceptionClear = function() pending = nil end,
    DeleteLocalRef = function() enter("DeleteLocalRef") end,
    NewStringUTF = function(_, s)
        if enter("NewStringUTF") then return nil end
        return jstr(s)
    end,
    FindClass = function(_, name)
        if enter("FindClass", name) then return nil end
        return { name = name }
    end,
    GetObjectClass = function(_, obj)
        if enter("GetObjectClass") then return nil end
        return obj.class or { name = "object" }
    end,
    GetMethodID = function(_, _, name)
        if enter("GetMethodID", name) then return nil end
        return { name = name }
    end,
    GetStaticMethodID = function(_, _, name)
        if enter("GetStaticMethodID", name) then return nil end
        return { name = name }
    end,
    NewObject = function()
        if enter("NewObject") then return nil end
        return { bundle = {} }
    end,
    CallStaticObjectMethod = function(_, _, mid)
        if enter("CallStaticObjectMethod", mid.name) then return nil end
        return { uri = true }
    end,
    CallVoidMethod = function(_, obj, mid, k, v)
        if enter("CallVoidMethod", mid.name) then return end
        if mid.name == "putString" then
            obj.bundle[k.str] = v.str
            sent_extras = obj.bundle
        end
    end,
    CallObjectMethod = function(_, obj, mid)
        if enter("CallObjectMethod", mid.name) then return nil end
        if mid.name == "toString" then return jstr("java.lang.RuntimeException: " .. obj.text) end
        if mid.name == "getString" then return jstr(helper_reply) end
        return {}
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

local jni = { env = env }
function jni:context(_, fn) return fn(self) end

package.preload["android"] = function()
    return { jni = jni, app = { activity = { vm = {}, clazz = { class = { name = "Activity" } } } } }
end

local Helper = require("nookwifihelper")

-- Tests ------------------------------------------------------------------------

local passed, failed = 0, 0
local function test(name, fn)
    throw_at, pending, violations, sent_extras = nil, nil, {}, nil
    helper_reply = '{"ok":true,"protocol":1}'
    local ok, err = pcall(fn)
    if ok and #violations > 0 then
        ok, err = false, "JNI calls with an exception pending: " .. table.concat(violations, ", ")
    end
    if ok and pending then
        ok, err = false, "exception left pending"
    end
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end

test("successful call returns the decoded reply", function()
    local reply, err = Helper.call("ping")
    assert(reply and reply.ok and not err, "no reply: " .. tostring(err))
end)

test("extras reach the Bundle", function()
    Helper.call("join", nil, { ssid = "Home", password = "secret123" })
    assert(sent_extras and sent_extras.ssid == "Home" and sent_extras.password == "secret123", "extras missing")
end)

test("missing helper maps to helper_not_installed", function()
    throw_at = "CallObjectMethod:call"
    local saved = env[0].CallObjectMethod
    env[0].CallObjectMethod = function(e, obj, mid, ...)
        if mid.name == "call" then
            pending = { class = { name = "java/lang/IllegalArgumentException" },
                text = "Unknown URI content://dev.nookwifi.helper" }
            return nil
        end
        return saved(e, obj, mid, ...)
    end
    local reply, err = Helper.call("ping")
    env[0].CallObjectMethod = saved
    assert(reply == nil and err == "helper_not_installed", "error was " .. tostring(err))
end)

test("protocol mismatch is reported", function()
    helper_reply = '{"ok":true,"protocol":2}'
    local reply, err = Helper.call("ping")
    assert(reply == nil and err == "protocol_mismatch", "error was " .. tostring(err))
end)

-- Make every raw JNI step throw in turn (or fail to allocate); the client must
-- stop cleanly each time, with nothing left pending.
local steps = {
    "NewStringUTF",
    "FindClass:android/net/Uri", "GetStaticMethodID:parse", "CallStaticObjectMethod:parse",
    "FindClass:android/os/Bundle", "GetMethodID:<init>", "NewObject",
    "GetObjectClass", "GetMethodID:putString", "CallVoidMethod:putString",
    "GetMethodID:getContentResolver", "CallObjectMethod:getContentResolver",
    "GetMethodID:call", "CallObjectMethod:call",
    "GetMethodID:getString", "CallObjectMethod:getString",
    "GetStringUTFChars",
}
for _, step in ipairs(steps) do
    test("failure at " .. step .. " stops cleanly", function()
        throw_at = step
        local reply, err = Helper.call("join", "arg", { ssid = "Home", password = "secret123" })
        assert(reply == nil, "got a reply after a failure")
        assert(err == "jni_error", "error was " .. tostring(err))
    end)
end

test("describing an exception that itself fails still clears everything", function()
    throw_at = "CallObjectMethod:call"
    local saved = env[0].CallObjectMethod
    env[0].CallObjectMethod = function(e, obj, mid, ...)
        if mid.name == "toString" then
            pending = { class = { name = "java/lang/OutOfMemoryError" }, text = "oom" }
            return nil
        end
        return saved(e, obj, mid, ...)
    end
    local reply, err = Helper.call("ping")
    env[0].CallObjectMethod = saved
    assert(reply == nil and err == "jni_error", "error was " .. tostring(err))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
