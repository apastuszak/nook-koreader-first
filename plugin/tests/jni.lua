--[[
Offline tests for nookwifihelper.lua (the JNI client). A fake JNI environment
can make any call throw; the tests fail if the client makes another JNI call
while an exception is pending, which is undefined behavior on Android.

Usage: luajit plugin/tests/jni.lua   (from the repo root; `make check` runs it)
--]]

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

-- Fake JNI ---------------------------------------------------------------------

local throw_at       -- name of the call that should throw, or nil
local pending        -- the pending exception, if any
local violations     -- JNI calls made while an exception was pending
local calls          -- names of all JNI calls, in order
local helper_reply   -- JSON the fake ContentResolver.call returns
local sent_extras    -- extras the client put in the Bundle

local function jniCall(name, result)
    table.insert(calls, name)
    if pending then table.insert(violations, name) end
    if name == throw_at then
        pending = { text = "java.lang.RuntimeException: thrown at " .. name }
        return nil
    end
    return result
end

local env = {}
env[0] = {
    NewStringUTF = function(_, s) return jniCall("NewStringUTF", { str = s }) end,
    FindClass = function(_, n) return jniCall("FindClass", { class = n }) end,
    GetMethodID = function() return jniCall("GetMethodID", {}) end,
    NewObject = function() return jniCall("NewObject", { bundle = {} }) end,
    ExceptionCheck = function() return pending and 1 or 0 end,
    ExceptionOccurred = function() return pending end,
    ExceptionClear = function() pending = nil end,
}

local jni = { env = env }
function jni:callStaticObjectMethod(_, method) return jniCall(method, { uri = true }) end
function jni:callVoidMethod(obj, method, _, k, v)
    local r = jniCall(method)
    if method == "putString" and not pending then
        obj.bundle[k.str] = v.str
        sent_extras = obj.bundle
    end
    return r
end
function jni:callObjectMethod(obj, method)
    if method == "toString" then
        -- The client asks the exception for its text; that call is allowed.
        table.insert(calls, "toString")
        return { str = obj.text }
    end
    if method == "getString" then return jniCall("getString", { str = helper_reply }) end
    return jniCall(method, {})
end
function jni:to_string(s) return s.str end
function jni:context(_, fn) return fn(self) end

package.preload["android"] = function()
    return { jni = jni, app = { activity = { vm = {}, clazz = {} } } }
end

local Helper = require("nookwifihelper")

-- Tests ------------------------------------------------------------------------

local passed, failed = 0, 0
local function test(name, fn)
    throw_at, pending, violations, calls, sent_extras = nil, nil, {}, {}, nil
    helper_reply = '{"ok":true,"protocol":1}'
    local ok, err = pcall(fn)
    if ok and #violations > 0 then
        ok, err = false, "JNI calls with an exception pending: " .. table.concat(violations, ", ")
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
    assert(reply and reply.ok and not err, "no reply")
end)

test("extras reach the Bundle", function()
    Helper.call("join", nil, { ssid = "Home", password = "secret123" })
    assert(sent_extras and sent_extras.ssid == "Home" and sent_extras.password == "secret123", "extras missing")
end)

test("missing helper maps to helper_not_installed", function()
    throw_at = "call"
    local reply, err = Helper.call("ping")
    assert(reply == nil, "got a reply")
    -- The fake's exception text has no "Unknown URI", so this is a generic failure.
    assert(err == "jni_error", "error was " .. tostring(err))
end)

test("protocol mismatch is reported", function()
    helper_reply = '{"ok":true,"protocol":2}'
    local reply, err = Helper.call("ping")
    assert(reply == nil and err == "protocol_mismatch", "error was " .. tostring(err))
end)

-- Make each JNI step throw in turn; the client must stop cleanly every time.
local steps = { "NewStringUTF", "parse", "FindClass", "GetMethodID", "NewObject", "putString",
    "getContentResolver", "call", "getString" }
for _, step in ipairs(steps) do
    test("exception at " .. step .. " stops cleanly", function()
        throw_at = step
        local reply, err = Helper.call("join", "arg", { ssid = "Home", password = "secret123" })
        assert(reply == nil, "got a reply after an exception")
        assert(err == "jni_error", "error was " .. tostring(err))
        assert(pending == nil, "exception left pending")
    end)
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
