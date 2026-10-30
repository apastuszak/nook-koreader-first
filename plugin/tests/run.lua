--[[
Offline tests for nookwifi.koplugin. Runs the plugin's real code against
stand-ins for KOReader modules and the helper, so menu building, polling flows
and NetworkMgr hooks execute without a device.

Usage: luajit plugin/tests/run.lua   (from the repo root; `make check` runs it)
--]]

local PLUGIN_DIR = "plugin/nookwifi.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

-- Fake clock and scheduler -------------------------------------------------

local now = 0
local queue = {}
local shown = {}
local events = {}

local function runScheduled(max_steps)
    for _ = 1, max_steps or 500 do
        local job = table.remove(queue, 1)
        if not job then return end
        now = now + job.delay
        job.fn()
    end
    error("scheduler did not settle")
end

package.preload["ui/time"] = function()
    return {
        now = function() return now end,
        since = function(t) return now - t end,
        to_s = function(t) return t end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) table.insert(shown, w) end,
        close = function() end,
        scheduleIn = function(_, delay, fn, ...)
            local args = { ... }
            table.insert(queue, { delay = delay, fn = function() fn(unpack(args)) end })
        end,
        broadcastEvent = function(_, ev) table.insert(events, ev.name) end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, o) return o end }
end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["ffi/util"] = function()
    return {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    }
end
package.preload["logger"] = function()
    local noop = function() end
    return { info = noop, warn = noop, dbg = noop }
end

local device = { isAndroid = function() return true end, hasSeamlessWifiToggle = function() return false end }
package.preload["device"] = function() return device end

local stock_calls = {}
local NM = {
    isWifiOn = function() table.insert(stock_calls, "isWifiOn") return "stock" end,
    turnOnWifi = function() table.insert(stock_calls, "turnOnWifi") end,
    turnOffWifi = function() table.insert(stock_calls, "turnOffWifi") end,
    getCurrentNetwork = function() table.insert(stock_calls, "getCurrentNetwork") end,
    getWifiMenuTable = function() return "settings-item" end,
    getWifiToggleMenuTable = function() return "toggle-item" end,
    queryNetworkState = function() end,
}
package.preload["ui/network/manager"] = function() return NM end
package.preload["android"] = function() return { openWifiSettings = function() end } end

-- Fake helper ---------------------------------------------------------------
-- `wifi` is the simulated device. `script(method, arg)` may override replies;
-- `on_poll(n)` can mutate `wifi` on each getState call.

local wifi, helper_missing, on_poll, polls
local function resetWifi()
    wifi = {
        enabled = true, connection = "connected", networkId = 1, ssid = "Home",
        locationPermission = true,
        saved = {
            { networkId = 0, ssid = "Cafe", status = "enabled", security = "open" },
            { networkId = 1, ssid = "Home", status = "current", security = "wpa_psk", signalLevel = 4 },
            { networkId = 2, status = "enabled", security = "wpa_psk" }, -- hidden SSID
        },
        scanAvailable = true,
    }
    helper_missing, on_poll, polls = false, nil, 0
end

local function stateReply()
    local s = {
        ok = true, protocol = 1,
        wifiState = wifi.enabled and "enabled" or "disabled",
        enabled = wifi.enabled,
        locationPermission = wifi.locationPermission,
        connection = wifi.enabled and wifi.connection or "disconnected",
    }
    if s.connection == "connected" then
        s.networkId, s.rssi, s.signalLevel, s.linkMbps, s.ip = wifi.networkId, -50, 4, 72, "10.0.0.2"
        if wifi.locationPermission then s.ssid = wifi.ssid end
    end
    return s
end

package.preload["nookwifihelper"] = function()
    return {
        PROTOCOL = 1,
        call = function(method, arg)
            if helper_missing then return nil, "helper_not_installed" end
            if method == "getState" then
                polls = polls + 1
                if on_poll then on_poll(polls) end
                return stateReply()
            elseif method == "setEnabled" then
                wifi.enabled = arg == "true"
                return stateReply()
            elseif method == "listSaved" then
                return { ok = true, protocol = 1, networks = wifi.saved, scanAvailable = wifi.scanAvailable }
            elseif method == "connectSaved" or method == "reconnect" then
                if not wifi.enabled then return { ok = false, error = "wifi_disabled", protocol = 1 } end
                return stateReply()
            elseif method == "ping" then
                return { ok = true, protocol = 1, versionName = "test" }
            end
            return { ok = false, error = "unknown_method", protocol = 1 }
        end,
    }
end

-- Test runner ---------------------------------------------------------------

local passed, failed = 0, 0
local function test(name, fn)
    resetWifi()
    now, queue, shown, events, stock_calls = 0, {}, {}, {}, {}
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end
local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", what or "value", tostring(expected), tostring(actual)), 2)
    end
end
local function lastMessage() return shown[#shown] and shown[#shown].text end
local function has(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

-- Evaluates every dynamic field of a menu, as TouchMenu would when drawing it.
local function renderMenu(items)
    local texts = {}
    for _, item in ipairs(items) do
        local text = item.text_func and item.text_func() or item.text
        assert(type(text) == "string" and text ~= "", "menu item without text")
        if item.checked_func then item.checked_func() end
        if item.enabled_func then item.enabled_func() end
        if item.sub_item_table_func then renderMenu(item.sub_item_table_func()) end
        table.insert(texts, text)
    end
    return texts
end

local NookWifi = dofile(PLUGIN_DIR .. "/main.lua")
local Network = require("nookwifinetwork")
local function newPlugin()
    local menu_items = {}
    local plugin = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = NookWifi })
    plugin:init()
    plugin:addToMainMenu(menu_items)
    return plugin, menu_items.nookwifi.sub_item_table
end
local function savedMenuOf(items)
    for _, item in ipairs(items) do
        if item.sub_item_table_func then return item.sub_item_table_func() end
    end
    error("no saved networks submenu")
end

-- Menu ----------------------------------------------------------------------

test("main menu renders", function()
    local _, items = newPlugin()
    local texts = renderMenu(items)
    eq(texts[1], "Status: Connected to Home", "status line")
end)

test("main menu renders with helper missing", function()
    helper_missing = true
    local _, items = newPlugin()
    eq(renderMenu(items)[1], "Status: Nook Wi-Fi Helper is not installed.", "status line")
end)

test("status without location permission hides name", function()
    wifi.locationPermission = false
    local _, items = newPlugin()
    eq(renderMenu(items)[1], "Status: Connected (name hidden)", "status line")
end)

test("saved networks sorted with labels", function()
    local _, items = newPlugin()
    local texts = renderMenu(savedMenuOf(items))
    eq(texts[1], "Home · signal 4/4", "first")
    eq(texts[2], "(hidden network) · not in range", "second")
    eq(texts[3], "Cafe · not in range", "third")
end)

test("saved networks without scan info have no range labels", function()
    wifi.scanAvailable = false
    local _, items = newPlugin()
    eq(renderMenu(savedMenuOf(items))[1], "Home", "first")
end)

test("saved networks empty and error cases", function()
    wifi.saved = {}
    local _, items = newPlugin()
    eq(renderMenu(savedMenuOf(items))[1], "No saved networks", "empty")
    helper_missing = true
    eq(renderMenu(savedMenuOf(items))[1], "Nook Wi-Fi Helper is not installed.", "missing")
end)

-- Operations ----------------------------------------------------------------

test("turn off waits for disabled", function()
    local plugin = newPlugin()
    plugin:setWifi(false)
    runScheduled()
    eq(lastMessage(), "Wi-Fi is off.", "message")
    assert(has(events, "NetworkDisconnected"), "NetworkDisconnected not broadcast")
    eq(plugin.busy, false, "busy")
end)

test("turn on waits for connection", function()
    wifi.enabled = false
    local plugin = newPlugin()
    wifi.connection = "connecting"
    on_poll = function(n) if n >= 4 then wifi.connection = "connected" end end
    plugin:setWifi(true)
    runScheduled()
    eq(lastMessage(), "Wi-Fi is on. Connected to Home.", "message")
    assert(has(events, "NetworkConnected"), "NetworkConnected not broadcast")
end)

test("turn on times out without connection", function()
    wifi.enabled = false
    local plugin = newPlugin()
    wifi.connection = "disconnected"
    plugin:setWifi(true)
    runScheduled()
    eq(lastMessage(), "Wi-Fi is on but not connected to a network.", "message")
end)

test("connect to saved network succeeds", function()
    local plugin = newPlugin()
    on_poll = function(n)
        if n == 2 then wifi.connection = "disconnected" end
        if n == 4 then wifi.connection, wifi.networkId, wifi.ssid = "connected", 0, "Cafe" end
    end
    plugin:connectSaved(wifi.saved[1])
    runScheduled()
    eq(lastMessage(), "Connected to Cafe.", "message")
end)

test("connect reports Android falling back to another network", function()
    local plugin = newPlugin()
    on_poll = function(n)
        if n == 2 then wifi.connection = "disconnected" end
        if n == 4 then wifi.connection = "connected" end -- back on Home
    end
    plugin:connectSaved(wifi.saved[1])
    runScheduled()
    eq(lastMessage(), "Could not connect to Cafe. Connected to Home instead.", "message")
end)

test("connect times out", function()
    local plugin = newPlugin()
    on_poll = function() wifi.connection = "disconnected" end
    plugin:connectSaved(wifi.saved[1])
    runScheduled()
    eq(lastMessage(), "Could not connect to Cafe. It may be out of range.", "message")
end)

test("connect turns Wi-Fi on first", function()
    wifi.enabled = false
    local plugin = newPlugin()
    plugin:connectSaved(wifi.saved[2])
    runScheduled()
    eq(lastMessage(), "Connected to Home.", "message")
end)

test("reconnect with Wi-Fi off turns it on", function()
    wifi.enabled = false
    local plugin = newPlugin()
    plugin:reconnect()
    runScheduled()
    eq(lastMessage(), "Wi-Fi is on. Connected to Home.", "message")
end)

test("busy blocks a second operation", function()
    local plugin = newPlugin()
    plugin:setWifi(false)
    local before = #shown
    plugin:reconnect()
    eq(#shown, before, "second operation showed something")
    runScheduled()
end)

-- NetworkMgr hooks ------------------------------------------------------------

test("hooks route through helper", function()
    Network.install()
    eq(device:hasSeamlessWifiToggle(), true, "seamless")
    eq(NM:isWifiOn(), true, "isWifiOn")
    eq(NM:getWifiMenuTable(), "toggle-item", "menu")
    eq(NM:getCurrentNetwork().ssid, "Home", "current network")
    local called = false
    eq(NM:turnOnWifi(function() called = true end), true, "turnOnWifi")
    assert(called, "turnOnWifi callback not run")
    called = false
    NM:turnOffWifi(function() called = true end)
    runScheduled()
    assert(called and not wifi.enabled, "turnOffWifi did not finish")
end)

test("hooks fall back to stock when helper missing", function()
    Network.install()
    helper_missing = true
    eq(NM:isWifiOn(), "stock", "isWifiOn")
    NM:turnOnWifi()
    NM:turnOffWifi()
    assert(has(stock_calls, "turnOnWifi") and has(stock_calls, "turnOffWifi"), "no stock fallback")
    eq(NM:getWifiMenuTable(), "settings-item", "menu")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
