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
        close = function(_, w) if w and w.onCloseWidget then w:onCloseWidget() end end,
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
-- Logger that records debug lines, so tests can check nothing sensitive is logged.
local debug_lines = {}
local logger = { levels = { dbg = 1, info = 2, warn = 3, err = 4 } }
local function record(...) table.insert(debug_lines, table.concat({ ... }, " ")) end
local noop = function() end
function logger:setLevel(lvl) self.dbg = lvl <= 1 and record or noop end
logger.info, logger.warn = noop, noop
logger:setLevel(logger.levels.info)
package.preload["logger"] = function() return logger end
local dbg_state = { is_on = false }
package.preload["dbg"] = function() return dbg_state end

-- Widgets: constructors return their options; dialogs record what is shown.
local function widgetClass()
    local class = {}
    class.__index = class
    function class:new(o) return setmetatable(o, class) end
    return class
end
package.preload["ui/widget/menu"] = widgetClass
package.preload["ui/widget/confirmbox"] = widgetClass
package.preload["ui/widget/inputdialog"] = function()
    local InputDialog = widgetClass()
    function InputDialog:getInputText() return self._typed or "" end
    function InputDialog:onShowKeyboard() end
    function InputDialog.onCloseWidget() end
    return InputDialog
end

local device = { isAndroid = function() return true end, hasSeamlessWifiToggle = function() return false end }
package.preload["device"] = function() return device end

local stock_calls = {}
local NM = {
    isWifiOn = function() table.insert(stock_calls, "isWifiOn") return "stock" end,
    turnOnWifi = function() table.insert(stock_calls, "turnOnWifi") end,
    -- Like device_android.lua: opens Settings, then runs the callback at once.
    turnOffWifi = function(_, cb)
        table.insert(stock_calls, "turnOffWifi")
        if cb then cb() end
    end,
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
        visible = {
            { ssid = "Home", signalLevel = 4, security = "wpa_psk", current = true, savedNetworkId = 1 },
            { ssid = "Neighbor", signalLevel = 3, security = "wpa_psk", current = false },
            { ssid = "Library", signalLevel = 2, security = "open", current = false },
            { ssid = "Office", signalLevel = 3, security = "eap", current = false },
        },
        correct_password = "correct horse",
        auth_failed = false,
        forgotten = {},
        forget_allowed = true, -- false behaves like this Nook's firmware
        join_args = nil,
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
        authFailed = wifi.auth_failed,
        authFailedNetworkId = wifi.auth_failed and wifi.auth_failed_id or nil,
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
        call = function(method, arg, extras)
            if helper_missing then return nil, "helper_not_installed" end
            if wifi.fail_method == method then return nil, wifi.fail_error end
            if method == "getState" then
                if wifi.getstate_fail then return nil, "jni_error" end
                polls = polls + 1
                if on_poll then on_poll(polls) end
                return stateReply()
            elseif method == "setEnabled" then
                if wifi.set_enabled_rejected then
                    local r = stateReply()
                    r.ok, r.error = false, "request_rejected"
                    return r
                end
                if not (wifi.ignore_off and arg == "false") then wifi.enabled = arg == "true" end
                return stateReply()
            elseif method == "listSaved" then
                return { ok = true, protocol = 1, networks = wifi.saved, scanAvailable = wifi.scanAvailable }
            elseif method == "connectSaved" or method == "reconnect" then
                if not wifi.enabled then return { ok = false, error = "wifi_disabled", protocol = 1 } end
                if method == "connectSaved" and wifi.stored_password_wrong then
                    local start = polls
                    on_poll = function(n)
                        if n == start + 2 then wifi.connection, wifi.auth_failed = "disconnected", true end
                    end
                end
                return stateReply()
            elseif method == "scan" then
                if not wifi.locationPermission then
                    return { ok = false, error = "location_permission_needed", protocol = 1 }
                end
                return { ok = true, protocol = 1 }
            elseif method == "scanResults" then
                return { ok = true, protocol = 1, networks = wifi.visible, fresh = polls >= 0 }
            elseif method == "join" then
                wifi.join_args = extras
                if wifi.join_already_saved then
                    return { ok = false, error = "already_saved", savedNetworkId = wifi.join_already_saved, protocol = 1 }
                end
                local id = 10
                local start = polls -- simulate relative to this call, not the test start
                -- Simulated Android: the right password connects, a wrong one fails auth.
                if extras.security == "open" or extras.password == wifi.correct_password then
                    on_poll = function(n)
                        if n == start + 2 then wifi.connection, wifi.networkId, wifi.ssid = "connected", id, extras.ssid end
                    end
                else
                    on_poll = function(n)
                        if n == start + 2 then wifi.connection, wifi.auth_failed = "disconnected", true end
                    end
                end
                -- Like the real helper, the reply also carries the *current*
                -- connection's fields, including its networkId.
                local reply = stateReply()
                reply.createdNetworkId = id
                -- The Nook drops the old connection right after join (seen in logcat).
                wifi.connection = "disconnected"
                return reply
            elseif method == "forget" then
                if not wifi.forget_allowed then return { ok = false, error = "request_rejected", protocol = 1 } end
                table.insert(wifi.forgotten, tonumber(arg))
                return { ok = true, protocol = 1 }
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
    wifi.saved[1].signalLevel = 2 -- Cafe seen in the last scan
    local _, items = newPlugin()
    local texts = renderMenu(savedMenuOf(items))
    eq(texts[1], "Home · signal 4/4", "first")
    eq(texts[2], "Cafe · signal 2/4", "second")
    eq(texts[3], "(hidden network)", "third")
end)

test("current network shows live signal even when missing from the last scan", function()
    -- A partial background scan left the connected network out of the results.
    wifi.saved[2].signalLevel = nil
    local _, items = newPlugin()
    local texts = renderMenu(savedMenuOf(items))
    eq(texts[1], "Home · signal 4/4", "first")
    for _, text in ipairs(texts) do
        assert(not text:find("not in range", 1, true), "claims not in range: " .. text)
    end
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

-- Scanning and joining ------------------------------------------------------

-- Runs a scan and returns the results Menu that was shown.
local function scanAndGetMenu(plugin)
    plugin:scanNetworks()
    runScheduled()
    for i = #shown, 1, -1 do
        if shown[i].item_table then return shown[i] end
    end
    error("no results menu shown; last message: " .. tostring(lastMessage()))
end
local function itemFor(menu, ssid)
    for _, item in ipairs(menu.item_table) do
        if item.text == ssid then return item end
    end
    error("no item for " .. ssid)
end

test("scan lists networks sorted with labels", function()
    local menu = scanAndGetMenu(newPlugin())
    eq(menu.item_table[1].text, "Home", "first")
    eq(menu.item_table[1].mandatory, "4/4 · connected", "current label")
    eq(itemFor(menu, "Library").mandatory, "2/4 · open", "open label")
    eq(itemFor(menu, "Office").mandatory, "3/4 · not supported", "eap label")
end)

test("scan without location permission explains how to grant it", function()
    wifi.locationPermission = false
    newPlugin():scanNetworks()
    assert(lastMessage():find("pm grant", 1, true), "no ADB grant instructions")
    assert(lastMessage():find("Allow location access", 1, true), "no setup-screen instructions")
end)

test("unsupported security is explained, not joined", function()
    local plugin = newPlugin()
    itemFor(scanAndGetMenu(plugin), "Office").callback()
    assert(lastMessage():find("WPA Enterprise", 1, true), "no unsupported message")
    eq(wifi.join_args, nil, "join was called")
end)

test("open network joins without a password", function()
    local plugin = newPlugin()
    itemFor(scanAndGetMenu(plugin), "Library").callback()
    runScheduled()
    eq(wifi.join_args.password, nil, "password sent")
    eq(lastMessage(), "Connected to Library.", "message")
end)

-- Opens the password dialog for ssid and types password into it.
local function passwordDialogFor(plugin, ssid, password)
    itemFor(scanAndGetMenu(plugin), ssid).callback()
    local dialog = shown[#shown]
    assert(dialog.text_type == "password", "no password dialog")
    dialog._typed = password
    return dialog
end
local function pressConnect(dialog) dialog.buttons[1][2].callback() end

test("WPA network joins with the right password", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "correct horse"))
    runScheduled()
    eq(lastMessage(), "Connected to Neighbor.", "message")
    eq(#wifi.forgotten, 0, "forgot a working network")
end)

test("wrong password is reported and the new network forgotten", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "wrong password"))
    runScheduled()
    eq(lastMessage(), "Wrong password for Neighbor.", "message")
    eq(wifi.forgotten[1], 10, "forgotten network")
end)

test("too-short password is rejected before calling the helper", function()
    local plugin = newPlugin()
    local dialog = passwordDialogFor(plugin, "Neighbor", "short")
    pressConnect(dialog)
    eq(lastMessage(), "Wi-Fi passwords must be 8 to 63 characters.", "message")
    eq(wifi.join_args, nil, "join was called")
end)

test("non-ASCII password is rejected", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "caf\u{E9} au lait"))
    assert(lastMessage():find("ASCII", 1, true), "no ASCII message")
end)

test("debug logging is off while typing a password and restored after", function()
    dbg_state.is_on = true
    logger:setLevel(logger.levels.dbg)
    debug_lines = {}
    local plugin = newPlugin()
    local dialog = passwordDialogFor(plugin, "Neighbor", "correct horse")
    logger.dbg("add char", "c") -- what KOReader's keyboard does per keystroke
    eq(#debug_lines, 0, "debug line logged while dialog open")
    pressConnect(dialog)
    logger.dbg("after")
    eq(#debug_lines, 1, "debug logging not restored")
    runScheduled()
    dbg_state.is_on = false
    logger:setLevel(logger.levels.info)
end)

test("cancelling the password dialog restores debug logging", function()
    dbg_state.is_on = true
    logger:setLevel(logger.levels.dbg)
    debug_lines = {}
    local plugin = newPlugin()
    local dialog = passwordDialogFor(plugin, "Neighbor", "")
    dialog.buttons[1][1].callback()
    logger.dbg("after")
    eq(#debug_lines, 1, "debug logging not restored")
    dbg_state.is_on = false
    logger:setLevel(logger.levels.info)
end)

test("failed join never forgets the network that was connected before", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "wrong password"))
    runScheduled()
    for _, id in ipairs(wifi.forgotten) do
        assert(id ~= 1, "forgot the previously connected network")
    end
    eq(wifi.forgotten[1], 10, "forgotten network")
end)

test("successful join is recognised even when the reply's networkId is the old network", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "correct horse"))
    runScheduled()
    eq(lastMessage(), "Connected to Neighbor.", "message")
end)

test("wrong password when forget is refused points to Android settings", function()
    wifi.forget_allowed = false
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "wrong password"))
    runScheduled()
    local box = shown[#shown]
    assert(box.ok_callback and box.ok_text == "Wi-Fi settings", "no Android settings prompt")
    assert(box.text:find("Wrong password for Neighbor.", 1, true), "prompt does not say wrong password")
    eq(plugin.busy, false, "busy")
end)

test("saved network with a wrong stored password points to Android settings", function()
    wifi.stored_password_wrong = true
    local plugin = newPlugin()
    plugin:connectSaved(wifi.saved[1])
    runScheduled()
    local box = shown[#shown]
    assert(box.ok_callback and box.text:find("saved password for Cafe", 1, true), "no Android settings prompt")
end)

test("saved networks offer no forget action", function()
    local _, items = newPlugin()
    for _, item in ipairs(savedMenuOf(items)) do
        eq(item.hold_callback, nil, "hold_callback")
    end
end)

-- Fixes from the 1.0.0 code review ------------------------------------------

test("join of a network saved meanwhile with a wrong password points to settings", function()
    wifi.join_already_saved = 0 -- Cafe
    wifi.stored_password_wrong = true
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "correct horse"))
    runScheduled()
    local box = shown[#shown]
    assert(box.ok_callback and box.text:find("saved password", 1, true), "no Android settings prompt")
    assert(not has(events, "auth"), "broadcast a bogus 'auth' event")
end)

test("brief autojoin to another network after turning Wi-Fi on is not a failure", function()
    wifi.enabled = false
    local plugin = newPlugin()
    wifi.connection = "disconnected"
    on_poll = function(n)
        -- Wi-Fi comes up, Android autojoins Home (1) first, then switches to Cafe (0).
        if n == 4 then wifi.connection, wifi.networkId, wifi.ssid = "connected", 1, "Home" end
        if n == 6 then wifi.connection = "disconnected" end
        if n == 7 then wifi.connection, wifi.networkId, wifi.ssid = "connected", 0, "Cafe" end
    end
    plugin:connectSaved(wifi.saved[1])
    runScheduled()
    eq(lastMessage(), "Connected to Cafe.", "message")
end)

test("auth failure on another network is not blamed on the one being joined", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "correct horse"))
    -- Android briefly tried saved network 1 and its stored password failed.
    wifi.auth_failed, wifi.auth_failed_id = true, 1
    runScheduled()
    eq(lastMessage(), "Connected to Neighbor.", "message")
    eq(#wifi.forgotten, 0, "forgot a network that joined fine")
end)

test("auth failure with unknown network id is still reported", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "wrong password"))
    wifi.auth_failed_id = -1
    runScheduled()
    eq(lastMessage(), "Wrong password for Neighbor.", "message")
end)

test("hook: rejected turn-off falls back to stock instead of reporting off", function()
    Network.install()
    wifi.set_enabled_rejected = true
    local called = false
    NM:turnOffWifi(function() called = true end)
    runScheduled()
    assert(has(stock_calls, "turnOffWifi"), "no stock fallback")
    eq(called, false, "reported Wi-Fi off while it is on")
end)

-- Fixes from Codex's review ---------------------------------------------------

test("hook: Wi-Fi still on after the timeout is not reported as off", function()
    Network.install()
    wifi.ignore_off = true -- accepted, but the radio stays on
    local called = false
    NM:turnOffWifi(function() called = true end)
    runScheduled()
    eq(called, false, "reported Wi-Fi off while it is on")
end)

test("stale auth failure does not undo a successful join", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "correct horse"))
    -- A transient auth failure is still flagged when the connection succeeds.
    wifi.auth_failed, wifi.auth_failed_id = true, -1
    runScheduled()
    eq(lastMessage(), "Connected to Neighbor.", "message")
    eq(#wifi.forgotten, 0, "removed a working network")
end)

test("hook: helper lost while turning off falls back to stock", function()
    Network.install()
    wifi.ignore_off = true
    on_poll = function() end
    local called = false
    NM:turnOffWifi(function() called = true end)
    wifi.getstate_fail = true
    runScheduled()
    assert(has(stock_calls, "turnOffWifi"), "no stock fallback")
    eq(called, false, "reported Wi-Fi off")
end)

test("helper error while waiting after join still removes the new network", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "wrong password"))
    wifi.getstate_fail = true -- helper stops answering getState after join
    runScheduled()
    eq(wifi.forgotten[1], 10, "created network not removed")
    eq(plugin.busy, false, "busy")
end)

test("scan row uses the live connection, not the flag from scan time", function()
    local plugin = newPlugin()
    local menu = scanAndGetMenu(plugin)
    -- Since the scan, the Nook moved to Cafe (0); Home's row still says current.
    wifi.networkId, wifi.ssid = 0, "Cafe"
    local start = polls
    on_poll = function(n)
        if n == start + 3 then wifi.connection, wifi.networkId, wifi.ssid = "connected", 1, "Home" end
    end
    itemFor(menu, "Home").callback()
    runScheduled()
    eq(lastMessage(), "Connected to Home.", "message")
end)

-- Fixes from Codex's review of 1.0.2 ------------------------------------------

for _, err in ipairs({ "jni_error", "bad_reply", "protocol_mismatch" }) do
    test("hook: " .. err .. " on turn-off opens Settings without reporting off", function()
        Network.install()
        wifi.fail_method, wifi.fail_error = "setEnabled", err
        local called = false
        NM:turnOffWifi(function() called = true end)
        runScheduled()
        assert(has(stock_calls, "turnOffWifi"), "Settings not opened")
        eq(called, false, "reported Wi-Fi off while it may be on")
    end)
end

test("hook: missing helper keeps exact stock turn-off behavior", function()
    Network.install()
    helper_missing = true
    local called = false
    NM:turnOffWifi(function() called = true end)
    assert(has(stock_calls, "turnOffWifi"), "Settings not opened")
    eq(called, true, "stock callback not run")
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
