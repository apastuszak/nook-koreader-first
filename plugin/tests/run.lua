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
local closed = {}
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
        close = function(_, w)
            closed[w] = true
            if w and w.onCloseWidget then w:onCloseWidget() end
        end,
        scheduleIn = function(_, delay, fn, ...)
            local args = { ... }
            table.insert(queue, { delay = delay, orig = fn, fn = function() fn(unpack(args)) end })
        end,
        unschedule = function(_, fn)
            for i = #queue, 1, -1 do
                if queue[i].orig == fn then table.remove(queue, i) end
            end
        end,
        broadcastEvent = function(_, ev) table.insert(events, ev.name) end,
        isWidgetShown = function(_, w) return w ~= nil and w.shown == true end,
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
    -- Like KOReader's gettext: _("msgid"), and _.ngettext(singular, plural, n).
    return setmetatable({
        ngettext = function(singular, plural, n) return n == 1 and singular or plural end,
    }, { __call = function(_, s) return s end })
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

local registered_actions = {}
package.preload["dispatcher"] = function()
    return { registerAction = function(_, name, value) registered_actions[name] = value end }
end

-- KOReader's global settings (LuaSettings): only what the plugin uses.
local settings_store
local function resetSettings()
    settings_store = {}
    _G.G_reader_settings = {
        isTrue = function(_, key) return settings_store[key] == true end,
        flipNilOrFalse = function(_, key) settings_store[key] = not settings_store[key] or nil end,
    }
end
resetSettings()

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
        -- The power-off timer (helper PowerOps): power_off_timeout in ms, whether the
        -- user allowed "Modify system settings", and how often its screen was opened.
        power = { ms = 0, write_allowed = false, opened = 0 },
        -- openNookHome: how often the Nook home was opened; false if it is missing.
        nook_home_opened = 0, nook_home_available = true,
    }
    helper_missing, on_poll, polls = false, nil, 0
end

local function stateReply()
    local s = {
        ok = true, protocol = 1,
        wifiState = wifi.state_now or (wifi.enabled and "enabled" or "disabled"),
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

-- Simulated Bluetooth, modelled on Bluetooth Stage 0 (AGENTS.md): switching
-- passes through turning_on/turning_off for one poll; the paired list is empty
-- while Bluetooth is off (Android 8.1); turning off disconnects remotes, and a
-- remote reconnects only when a button is pressed (`bt_press`); discovery lasts
-- about 14 s (28 polls) and reports only named devices; a remote in pairing mode
-- goes bonding -> bonded, then Android connects it by itself.
local bt
local function resetBt()
    bt = {
        available = true, enabled = true, state = "on", hid_ready = true, screen_on = true,
        polls = 0, opened_settings = 0, scan_stops = 0, removed = {}, pair_failed = {},
        paired = {
            { address = "AA:00:00:00:00:01", name = "8BitDo Micro gamepad", remote = true, connection = "connected" },
        },
        nearby = {
            { address = "AA:00:00:00:00:02", name = "Page Turner", remote = true, appear = 2, pairing_mode = true },
            { address = "AA:00:00:00:00:03", name = "Phone", remote = false, appear = 1 },
            { address = "AA:00:00:00:00:04", remote = false, appear = 1 }, -- unnamed BLE device
        },
        scan_len = 28,
    }
end
-- Starts a test with Bluetooth off; like the device, nothing is connected then.
local function btStartOff()
    bt.enabled, bt.state = false, "off"
    for _, d in ipairs(bt.paired) do d.connection = "disconnected" end
end
local function btTick()
    bt.polls = bt.polls + 1
    if bt.pending ~= nil and bt.polls >= bt.pending_at then
        bt.enabled, bt.state, bt.pending = bt.pending, bt.pending and "on" or "off", nil
        if not bt.enabled then
            for _, d in ipairs(bt.paired) do d.connection = "disconnected" end
        end
        if bt.queued ~= nil and bt.queued ~= bt.enabled then
            bt.state = bt.queued and "turning_on" or "turning_off"
            bt.pending, bt.pending_at = bt.queued, bt.polls + 2
        end
        bt.queued = nil
    end
    if bt.forgetting and bt.polls >= bt.forgetting.at then
        for i, d in ipairs(bt.paired) do
            if d == bt.forgetting.dev then
                table.remove(bt.paired, i)
                d.bond, d.connection = "none", "disconnected"
                bt.removed[d.address] = true -- the helper saw BOND_STATE_CHANGED to none
            end
        end
        bt.forgetting = nil
    end
    if bt.pairing and bt.polls >= bt.pairing.next_at then
        local p = bt.pairing
        p.step = p.step + 1
        p.next_at = bt.polls + 1
        if p.dev.pairing_mode and p.step == 2 then
            p.dev.bond = "bonded"
            table.insert(bt.paired, p.dev)
        elseif p.dev.pairing_mode and p.step == 3 and not bt.no_auto_connect then
            p.dev.connection = "connected"
            bt.pairing = nil
        elseif not p.dev.pairing_mode and p.step == 3 then
            p.dev.bond = "none"
            bt.pair_failed[p.dev.address] = true -- the helper saw bonding -> none
            bt.pairing = nil
        end
    end
end
local function btReply(extra)
    local r = { ok = true, protocol = 1, available = bt.available, screenOn = bt.screen_on }
    if bt.available then
        r.bluetoothState, r.enabled, r.hidReady = bt.state, bt.enabled, bt.hid_ready
        r.discovering = bt.scan_at ~= nil
    end
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function btDescribe(d)
    -- Like Android 8.1's getBondState, which returns BOND_NONE while the
    -- Bluetooth service is down.
    local o = { address = d.address, name = d.name, remote = d.remote,
        bond = (bt.enabled and not bt.bond_query_fails) and (d.bond or "bonded") or "none" }
    if bt.hid_ready then o.connection = d.connection or "disconnected" end
    return o
end
local function btFind(address)
    for _, d in ipairs(bt.paired) do if d.address == address then return d end end
    for _, d in ipairs(bt.nearby) do if d.address == address then return d end end
end
local function btError(code) return btReply({ ok = false, error = code }) end
local function btCall(method, arg)
    if method == "btState" then
        btTick()
        return btReply()
    elseif method == "btSetEnabled" then
        if not bt.available then return btError("bt_unavailable") end
        if bt.reject_switch then return btError("request_rejected") end
        local on = arg == "true"
        if bt.pending ~= nil then
            -- Mid-transition, Android queues the request: the transition finishes,
            -- then Bluetooth switches again if the latest request differs.
            bt.queued = on
        elseif bt.enabled ~= on then
            bt.state = on and "turning_on" or "turning_off"
            bt.pending, bt.pending_at = on, bt.polls + 2
        end
        return btReply()
    elseif method == "btPaired" then
        local list = {}
        if bt.enabled then
            for _, d in ipairs(bt.paired) do table.insert(list, btDescribe(d)) end
        end
        return btReply({ devices = list })
    elseif method == "btDevice" then
        btTick()
        local d = btFind(arg)
        local o = d and btDescribe(d) or { address = arg, bond = "none" }
        o.forgotten = bt.removed[arg] or false
        o.pairFailed = bt.pair_failed[arg] or false
        return btReply({ device = o })
    elseif method == "btScan" then
        if not bt.enabled then return btError("bt_disabled") end
        if not wifi.locationPermission then return { ok = false, error = "location_permission_needed", protocol = 1 } end
        bt.scan_at = bt.polls
        return btReply()
    elseif method == "btScanResults" then
        btTick()
        local elapsed = bt.polls - (bt.scan_at or bt.polls)
        local list = {}
        for _, d in ipairs(bt.nearby) do
            if d.name and elapsed >= d.appear then
                local o = btDescribe(d)
                o.bond = d.bond or "none"
                table.insert(list, o)
            end
        end
        for _, d in ipairs(bt.paired) do
            if d.name then table.insert(list, btDescribe(d)) end -- paired devices nearby also show up
        end
        local finished = elapsed >= bt.scan_len
        if finished then bt.scan_at = nil end
        return btReply({ devices = list, finished = finished })
    elseif method == "btScanStop" then
        bt.scan_stops = bt.scan_stops + 1
        -- The helper skips cancelDiscovery while bonding; it would cancel the
        -- pairing's remote-name request (seen on the Nook).
        if not bt.pairing then bt.scan_at = nil end
        return btReply()
    elseif method == "btPair" then
        if not bt.enabled then return btError("bt_disabled") end
        local d = btFind(arg)
        if d.bond == "bonded" then return btError("already_paired") end
        bt.scan_at = nil
        if bt.reject_pair then return btError("request_rejected") end
        bt.removed[arg] = nil
        bt.pair_failed[arg] = nil
        if bt.pair_fails_at_once then
            -- Bonding -> none within one poll (70 ms on the Nook).
            d.bond = "none"
            bt.pair_failed[arg] = true
            return btReply()
        end
        d.bond = "bonding" -- createBond reports bonding before it returns
        bt.pairing = { dev = d, step = 1, next_at = bt.polls + 1 }
        return btReply()
    elseif method == "btForget" then
        if bt.forget_unsupported then return btError("not_supported") end
        for _, d in ipairs(bt.paired) do
            if d.address == arg then
                -- Android 8.1 queues the removal: it happens on a later poll,
                -- or (bt.forget_never) the queued operation fails.
                if not bt.forget_never then bt.forgetting = { dev = d, at = bt.polls + 2 } end
                return btReply()
            end
        end
        return btError("not_paired")
    elseif method == "btOpenSettings" then
        bt.opened_settings = bt.opened_settings + 1
        return { ok = true, protocol = 1 }
    end
end

package.preload["nookwifihelper"] = function()
    return {
        PROTOCOL = 1,
        call = function(method, arg, extras)
            if helper_missing then return nil, "helper_not_installed" end
            if wifi.fail_method == method then return nil, wifi.fail_error end
            if method == "getState" then
                if wifi.getstate_fail then return nil, "jni_error" end
                -- Replay scripted wifiState transitions, one per poll (like the Nook,
                -- which reads "disabled" for up to ~1 s after a turn-on request).
                wifi.state_now = nil
                if wifi.state_script and #wifi.state_script > 0 then
                    wifi.state_now = table.remove(wifi.state_script, 1)
                end
                polls = polls + 1
                if on_poll then on_poll(polls) end
                return stateReply()
            elseif method == "setEnabled" then
                if wifi.set_enabled_rejected then
                    local r = stateReply()
                    r.ok, r.error = false, "request_rejected"
                    return r
                end
                local ignored = (wifi.ignore_off and arg == "false") or (wifi.ignore_on and arg == "true")
                if not ignored then wifi.enabled = arg == "true" end
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
            elseif method:sub(1, 2) == "bt" then
                local reply = btCall(method, arg)
                if reply then return reply end
            elseif method == "openNookHome" then
                if wifi.nook_home_unknown then -- a helper before this feature
                    return { ok = false, error = "unknown_method", protocol = 1 }
                end
                if not wifi.nook_home_available then
                    return { ok = false, error = "nook_home_unavailable", protocol = 1 }
                end
                wifi.nook_home_opened = wifi.nook_home_opened + 1
                return { ok = true, protocol = 1 }
            elseif method:sub(1, 8) == "powerOff" and wifi.power_unsupported then
                return { ok = false, error = "unknown_method", protocol = 1 } -- helper before 1.1.0
            elseif method:sub(1, 8) == "powerOff" and wifi.power_no_value and method ~= "powerOffOpenSettings" then
                return { ok = true, protocol = 1 } -- a broken helper build: no timeoutMs
            elseif method == "powerOffGet" then
                return { ok = true, protocol = 1, timeoutMs = wifi.power.ms }
            elseif method == "powerOffSet" then
                -- Like PowerRules: only the fixed list, as decimal milliseconds.
                local allowed = { ["0"] = 0, ["3600000"] = 3600000, ["21600000"] = 21600000,
                    ["86400000"] = 86400000, ["259200000"] = 259200000, ["604800000"] = 604800000 }
                if not allowed[arg] then return { ok = false, error = "bad_argument", protocol = 1 } end
                if not wifi.power.write_allowed then
                    return { ok = false, error = "write_settings_needed", protocol = 1 }
                end
                wifi.power.ms = allowed[arg]
                return { ok = true, protocol = 1, timeoutMs = wifi.power.ms }
            elseif method == "powerOffOpenSettings" then
                wifi.power.opened = wifi.power.opened + 1
                return { ok = true, protocol = 1 }
            end
            return { ok = false, error = "unknown_method", protocol = 1 }
        end,
    }
end

-- Test runner ---------------------------------------------------------------

local passed, failed = 0, 0
local NookWifi -- loaded below; test() resets its shared Bluetooth state
local function test(name, fn)
    resetWifi()
    resetBt()
    resetSettings()
    if NookWifi and NookWifi.bt_shared then
        local shared = NookWifi.bt_shared
        shared.pending_off, shared.off_for_sleep = nil, false
    end
    now, queue, shown, closed, events, stock_calls = 0, {}, {}, {}, {}, {}
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

NookWifi = dofile(PLUGIN_DIR .. "/main.lua")
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

test("turn on stops when Wi-Fi goes off while waiting for a connection", function()
    wifi.enabled = false
    local plugin = newPlugin()
    wifi.connection = "disconnected"
    local start
    on_poll = function(n)
        start = start or n
        if n == start + 3 then wifi.enabled = false end
    end
    plugin:setWifi(true)
    local before = polls
    runScheduled()
    eq(lastMessage(), "Wi-Fi is off.", "message")
    assert(has(events, "NetworkDisconnected"), "NetworkDisconnected not broadcast")
    assert(polls - before < 10, "kept polling after Wi-Fi went off")
end)

test("reconnect stops when Wi-Fi goes off", function()
    local plugin = newPlugin()
    wifi.connection = "disconnected"
    local start = polls
    on_poll = function(n) if n == start + 3 then wifi.enabled = false end end
    plugin:reconnect()
    runScheduled()
    eq(lastMessage(), "Wi-Fi is off.", "message")
end)

test("connection timeout with an uncertain state does not guess", function()
    local plugin = newPlugin()
    wifi.connection = "disconnected"
    -- Never "disabled", so only the timeout ends it. The helper reports
    -- enabled=false for "unknown" too, which must not be read as "off".
    local start = polls
    on_poll = function(n)
        if n > start + 2 then wifi.enabled, wifi.state_now = false, "unknown" end
    end
    plugin:reconnect()
    runScheduled()
    eq(lastMessage(), "Wi-Fi did not connect within 20 seconds.", "message")
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

test("connect stops when Wi-Fi goes off", function()
    local plugin = newPlugin()
    local start = polls
    on_poll = function(n)
        if n == start + 1 then wifi.connection = "disconnected" end
        if n == start + 3 then wifi.enabled = false end
    end
    plugin:connectSaved(wifi.saved[1])
    local before = polls
    runScheduled()
    eq(lastMessage(), "Wi-Fi is off.", "message")
    assert(polls - before < 10, "kept polling after Wi-Fi went off")
end)

test("connect that turned Wi-Fi on reports Disconnected when it goes off again", function()
    wifi.enabled = false
    local plugin = newPlugin()
    -- Comes on, never connects, and goes off a few polls after reaching "enabled".
    local on_polls = 0
    on_poll = function()
        if wifi.enabled then on_polls = on_polls + 1 end
        if on_polls == 4 then wifi.enabled = false end
    end
    wifi.connection = "disconnected"
    plugin:connectSaved(wifi.saved[1])
    runScheduled()
    assert(has(events, "NetworkConnecting"), "NetworkConnecting not broadcast")
    eq(lastMessage(), "Wi-Fi is off.", "message")
    assert(has(events, "NetworkDisconnected"), "NetworkDisconnected not broadcast")
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

test("join stops when Wi-Fi goes off and removes the new network", function()
    local plugin = newPlugin()
    pressConnect(passwordDialogFor(plugin, "Neighbor", "correct horse"))
    -- Replaces the fake join's own connect simulation.
    local start = polls
    on_poll = function(n) if n == start + 1 then wifi.enabled = false end end
    local before = polls
    runScheduled()
    eq(lastMessage(), "Wi-Fi is off.", "message")
    eq(wifi.forgotten[1], 10, "forgotten network")
    assert(polls - before < 10, "kept polling after Wi-Fi went off")
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

-- KOReader toggle feedback ------------------------------------------------------

test("hook: user toggle keeps a message up until connected, then names the network", function()
    Network.install()
    wifi.enabled = false
    local start = polls
    on_poll = function(n) if n == start + 4 then wifi.connection = "connected" end end
    wifi.connection = "connecting"
    NM:turnOnWifi(function() end, true)
    local progress = shown[#shown]
    eq(progress.text, "Turning on Wi-Fi…", "progress message")
    assert(progress.timeout == nil, "progress message times out on its own")
    runScheduled()
    eq(lastMessage(), "Wi-Fi on. Connected to Home.", "result message")
end)

-- Starts an interactive turn-on and returns the progress widget.
local function startToggle()
    NM:turnOnWifi(function() end, true)
    local progress = shown[#shown]
    eq(progress.text, "Turning on Wi-Fi…", "progress message")
    return progress
end

test("hook: progress survives the stale 'disabled' right after the request", function()
    Network.install()
    wifi.enabled = false
    wifi.connection = "connecting"
    wifi.state_script = { "disabled", "disabled", "enabling", "enabled" }
    local start = polls
    on_poll = function(n) if n == start + 5 then wifi.connection = "connected" end end
    local progress = startToggle()
    runScheduled()
    eq(lastMessage(), "Wi-Fi on. Connected to Home.", "result message")
    assert(closed[progress], "progress message not closed")
end)

test("hook: progress tolerates a passing 'unknown' state", function()
    Network.install()
    wifi.enabled = false
    wifi.connection = "connecting"
    wifi.state_script = { "enabling", "unknown", "enabled" }
    local start = polls
    on_poll = function(n) if n == start + 4 then wifi.connection = "connected" end end
    local progress = startToggle()
    runScheduled()
    eq(lastMessage(), "Wi-Fi on. Connected to Home.", "result message")
    assert(closed[progress], "progress message not closed")
end)

test("hook: turning on that fails partway says Wi-Fi is off", function()
    Network.install()
    wifi.enabled = false
    wifi.connection = "disconnected"
    -- Comes on, then the driver fails (or the user switches it off).
    wifi.state_script = { "enabling", "disabled" }
    local start = polls
    on_poll = function(n) if n == start + 2 then wifi.enabled = false end end
    local progress = startToggle()
    runScheduled()
    eq(lastMessage(), "Wi-Fi is off.", "message")
    assert(closed[progress], "progress message not closed")
end)

test("hook: progress timeout says Wi-Fi did not turn on when it is still off", function()
    Network.install()
    wifi.enabled = false
    wifi.ignore_on = true -- the request is accepted but Wi-Fi never comes on
    local progress = startToggle()
    runScheduled()
    eq(lastMessage(), "Wi-Fi did not turn on.", "message")
    assert(closed[progress], "progress message not closed")
end)

test("hook: non-interactive turn-on shows no extra message", function()
    Network.install()
    wifi.enabled = false
    NM:turnOnWifi(function() end) -- beforeWifiAction path: no interactive flag
    runScheduled()
    eq(#shown, 0, "showed a message")
end)

-- NetworkMgr hooks ------------------------------------------------------------

test("hooks route through helper", function()
    Network.install()
    eq(device:hasSeamlessWifiToggle(), true, "seamless")
    eq(NM:isWifiOn(), true, "isWifiOn")
    eq(NM:getWifiMenuTable(), "toggle-item", "menu")
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
    eq(device:hasSeamlessWifiToggle(), false, "seamless with no helper")
    NM:turnOnWifi()
    NM:turnOffWifi(function() end) -- interactive, as NetworkMgr:disableWifi calls it
    assert(has(stock_calls, "turnOnWifi") and has(stock_calls, "turnOffWifi"), "no stock fallback")
    eq(NM:getWifiMenuTable(), "settings-item", "menu")
end)

-- Fixes from the 1.0.3 code review ---------------------------------------------

test("getCurrentNetwork is left to stock, so lease checks are not armed", function()
    Network.install()
    -- KOReader's hasLeaseForCurrentNetwork treats a nil SSID as "unknown, do not
    -- disrupt"; an SSID with lease_ssid unset would force a needless reconnect.
    eq(NM:getCurrentNetwork(), nil, "getCurrentNetwork returned an SSID")
    assert(has(stock_calls, "getCurrentNetwork"), "stock getCurrentNetwork not used")
end)

test("seamless toggle follows the helper live", function()
    Network.install()
    eq(device:hasSeamlessWifiToggle(), true, "seamless with helper")
    wifi.fail_method, wifi.fail_error = "getState", "jni_error"
    eq(device:hasSeamlessWifiToggle(), false, "still seamless with a broken helper")
end)

for _, case in ipairs({
    { name = "rejected", setup = function() wifi.set_enabled_rejected = true end },
    { name = "broken helper", setup = function() wifi.fail_method, wifi.fail_error = "setEnabled", "jni_error" end },
    { name = "missing helper", setup = function() helper_missing = true end },
}) do
    test("background turn-off with a " .. case.name .. " never opens Settings", function()
        Network.install()
        case.setup()
        NM:turnOffWifi() -- NetworkMgr:_abortWifiConnection passes no callback
        runScheduled()
        eq(has(stock_calls, "turnOffWifi"), false, "opened Android Settings in the background")
    end)
end

test("connecting flow ending on another network still broadcasts NetworkConnected", function()
    wifi.enabled = false
    local plugin = newPlugin()
    wifi.connection = "disconnected"
    -- Cafe (0) is out of range; Android ends up on Home and stays there.
    on_poll = function(n) if n == 4 then wifi.connection, wifi.networkId, wifi.ssid = "connected", 1, "Home" end end
    plugin:connectSaved(wifi.saved[1])
    runScheduled()
    eq(lastMessage(), "Could not connect to Cafe. Connected to Home instead.", "message")
    assert(has(events, "NetworkConnected"), "NetworkConnected not broadcast")
end)

-- Bluetooth page-turner remotes -------------------------------------------------

local function newBtPlugin(reading)
    local menu_items = {}
    local plugin = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = NookWifi })
    plugin:init()
    plugin:addToMainMenu(menu_items)
    if reading then plugin.ui.document = {} end
    return plugin, menu_items.nookbluetooth.sub_item_table
end
local function itemNamed(items, text)
    for _, item in ipairs(items) do
        if (item.text_func and item.text_func() or item.text) == text then return item end
    end
    error("no menu item " .. text)
end
-- Like KOReader's Menu:onMenuSelect: the item's callback, then close_callback.
local function selectMenuItem(menu, i)
    menu.item_table[i].callback()
    if menu.close_callback then menu.close_callback() end
end
local function lastShownMenu()
    for i = #shown, 1, -1 do
        if shown[i].item_table then return shown[i] end
    end
end

test("bt: menu renders with a connected remote", function()
    local _, items = newBtPlugin()
    eq(renderMenu(items)[1], "Status: On, 8BitDo Micro gamepad connected", "status line")
    eq(registered_actions.nookbluetooth_toggle.event, "NookBluetoothToggle", "gesture action")
end)

test("bt: status lines for off, no remote, unavailable and missing helper", function()
    btStartOff()
    local _, items = newBtPlugin()
    eq(renderMenu(items)[1], "Status: Off", "off")
    resetBt()
    bt.paired[1].connection = "disconnected"
    _, items = newBtPlugin()
    eq(renderMenu(items)[1], "Status: On, no remote connected", "no remote")
    bt.available = false
    _, items = newBtPlugin()
    eq(renderMenu(items)[1], "Status: Not available", "unavailable")
    helper_missing = true
    _, items = newBtPlugin()
    eq(renderMenu(items)[1], "Status: Nook Wi-Fi Helper is not installed.", "helper missing")
end)

test("bt: turning off reports only once Bluetooth is off", function()
    local plugin = newBtPlugin()
    plugin:setBluetooth(false)
    eq(bt.state, "turning_off", "state right after the request")
    runScheduled()
    eq(lastMessage(), "Bluetooth off.", "message")
    eq(bt.enabled, false, "enabled")
    eq(bt.paired[1].connection, "disconnected", "remote")
    eq(plugin.busy, false, "busy")
end)

test("bt: turning on says to press a button on the remote", function()
    btStartOff()
    local plugin = newBtPlugin()
    plugin:setBluetooth(true)
    runScheduled()
    eq(lastMessage(), "Bluetooth on. Press a button on your remote to connect it.", "message")
end)

test("bt: a remote connecting after Bluetooth turned on is announced and refreshes the menu", function()
    btStartOff()
    local plugin = newBtPlugin()
    local updates = 0
    local touchmenu = { show_parent = { shown = true }, updateItems = function() updates = updates + 1 end }
    plugin:setBluetooth(true, touchmenu)
    -- The user presses a button on the remote 20 s later.
    local pressed = false
    local orig = btCall
    btCall = function(m, a)
        if not pressed and now >= 20 and bt.enabled then
            pressed = true
            bt.paired[1].connection = "connected"
        end
        return orig(m, a)
    end
    runScheduled()
    btCall = orig
    eq(lastMessage(), "8BitDo Micro gamepad connected.", "message")
    assert(updates >= 2, "menu not refreshed after the remote connected")
    assert(now < 25, "kept watching after the remote connected")
end)

test("bt: a remote connecting after the menu closed does not refresh the closed menu", function()
    btStartOff()
    local plugin = newBtPlugin()
    local updates = 0
    local touchmenu = { show_parent = { shown = true }, updateItems = function() updates = updates + 1 end }
    plugin:setBluetooth(true, touchmenu)
    local orig = btCall
    local before
    btCall = function(m, a)
        if not before and now >= 20 and bt.enabled then
            before = updates
            touchmenu.show_parent.shown = false -- the user closed the menu meanwhile
            bt.paired[1].connection = "connected"
        end
        return orig(m, a)
    end
    runScheduled()
    btCall = orig
    eq(lastMessage(), "8BitDo Micro gamepad connected.", "message")
    eq(updates, before, "menu refreshes after it closed")
end)

test("bt: watching for a remote gives up after a minute", function()
    btStartOff()
    local plugin = newBtPlugin()
    plugin:setBluetooth(true)
    runScheduled()
    eq(lastMessage(), "Bluetooth on. Press a button on your remote to connect it.", "message")
    assert(now <= 65, "watched for " .. now .. " s")
end)

test("bt: a rejected switch is reported", function()
    bt.reject_switch = true
    local plugin = newBtPlugin()
    plugin:setBluetooth(false)
    eq(lastMessage(), "Android rejected the Bluetooth request.", "message")
    eq(plugin.busy, nil, "busy")
end)

test("bt: switch timeout", function()
    local plugin = newBtPlugin()
    bt.state = "turning_off" -- never finishes
    local orig = btCall
    btCall = function(m, a)
        if m == "btSetEnabled" then return btReply() end
        local r = orig(m, a)
        bt.pending = nil
        return r
    end
    plugin:setBluetooth(false)
    runScheduled()
    btCall = orig
    eq(lastMessage(), "Bluetooth did not turn off within 10 seconds.", "message")
end)

test("bt: gesture toggles Bluetooth", function()
    local plugin = newBtPlugin()
    eq(plugin:onNookBluetoothToggle(), true, "handled")
    runScheduled()
    eq(lastMessage(), "Bluetooth off.", "message")
end)

test("bt: paired remotes list, connected first", function()
    table.insert(bt.paired, 1, { address = "AA:00:00:00:00:09", name = "Keyboard", remote = true })
    local _, items = newBtPlugin()
    local texts = renderMenu(itemNamed(items, "Paired remotes").sub_item_table_func())
    eq(texts[1], "8BitDo Micro gamepad · connected", "first")
    eq(texts[2], "Keyboard", "second")
end)

test("bt: paired remotes asks to turn Bluetooth on when it is off", function()
    btStartOff()
    local _, items = newBtPlugin()
    eq(renderMenu(itemNamed(items, "Paired remotes").sub_item_table_func())[1],
        "Turn on Bluetooth to see paired remotes.", "message")
end)

test("bt: hold to forget a remote", function()
    local _, items = newBtPlugin()
    local sub = itemNamed(items, "Paired remotes").sub_item_table_func()
    sub[1].hold_callback()
    local box = shown[#shown]
    eq(box.ok_text, "Forget", "confirm button")
    box.ok_callback()
    eq(#bt.paired, 1, "removed before Android processed it")
    eq(shown[#shown].text, "Forgetting 8BitDo Micro gamepad…", "progress")
    runScheduled()
    eq(#bt.paired, 0, "paired devices left")
    eq(lastMessage(), "Forgot 8BitDo Micro gamepad.", "message")
end)

test("bt: after forgetting, the stale paired list is left for the Bluetooth menu", function()
    local _, items = newBtPlugin()
    local went_up = 0
    local touchmenu = {
        show_parent = { shown = true },
        updateItems = function() end,
        backToUpperMenu = function() went_up = went_up + 1 end,
    }
    itemNamed(items, "Paired remotes").sub_item_table_func()[1].hold_callback(touchmenu)
    shown[#shown].ok_callback()
    runScheduled()
    eq(went_up, 1, "backToUpperMenu calls")
end)

test("bt: toggling while Bluetooth is turning on turns it off", function()
    btStartOff()
    local plugin, items = newBtPlugin()
    plugin:setBluetooth(true) -- now turning on
    queue = {} -- the user acts before the first poll
    plugin.busy = false
    eq(bt.state, "turning_on", "state")
    plugin.bt_cached = nil
    eq(itemNamed(items, "Bluetooth").checked_func(), true, "checkbox while turning on")
    plugin:onNookBluetoothToggle()
    runScheduled()
    eq(lastMessage(), "Bluetooth off.", "message")
    eq(bt.enabled, false, "enabled")
end)

test("bt: forget that Android never completes is reported, with the settings prompt", function()
    bt.forget_never = true
    local _, items = newBtPlugin()
    itemNamed(items, "Paired remotes").sub_item_table_func()[1].hold_callback()
    shown[#shown].ok_callback()
    runScheduled()
    local box = shown[#shown]
    eq(box.text, "Could not forget 8BitDo Micro gamepad. Try again, or use Android Bluetooth settings.", "text")
    eq(box.ok_text, "Bluetooth settings", "prompt button")
    eq(#bt.paired, 1, "paired devices left")
end)

test("bt: forget is not reported as done when Bluetooth turns off mid-removal", function()
    bt.forget_never = true
    local _, items = newBtPlugin()
    itemNamed(items, "Paired remotes").sub_item_table_func()[1].hold_callback()
    shown[#shown].ok_callback()
    bt.enabled, bt.state = false, "off" -- Bluetooth goes off before Android removes the bond
    runScheduled()
    for _, w in ipairs(shown) do
        assert(not (w.text or ""):find("^Forgot"), "claimed success: " .. tostring(w.text))
    end
    eq(shown[#shown].text, "Could not forget 8BitDo Micro gamepad. Try again, or use Android Bluetooth settings.", "text")
    eq(#bt.paired, 1, "paired devices left")
end)

test("bt: forget is not reported as done when the bond query fails with Bluetooth on", function()
    bt.forget_never = true
    local _, items = newBtPlugin()
    itemNamed(items, "Paired remotes").sub_item_table_func()[1].hold_callback()
    shown[#shown].ok_callback()
    bt.bond_query_fails = true -- getBondState returns BOND_NONE on a failed call
    runScheduled()
    for _, w in ipairs(shown) do
        assert(not (w.text or ""):find("^Forgot"), "claimed success: " .. tostring(w.text))
    end
    eq(#bt.paired, 1, "paired devices left")
end)

test("bt: sleeping while Bluetooth is still turning on turns it off", function()
    settings_store.nookbluetooth_while_reading = true
    btStartOff()
    local plugin = newBtPlugin(true)
    plugin:onReaderReady() -- book opened: Bluetooth starts turning on
    eq(bt.state, "turning_on", "state after opening")
    bt.screen_on = false
    plugin:onRequestSuspend() -- the Nook sleeps before it finished
    for _ = 1, 6 do btTick() end
    eq(bt.enabled, false, "Bluetooth finished turning on while asleep")
end)

test("bt: closing a book while Bluetooth is still turning on turns it off", function()
    settings_store.nookbluetooth_while_reading = true
    btStartOff()
    local plugin = newBtPlugin(true)
    plugin:onReaderReady()
    plugin:onCloseDocument()
    runScheduled() -- the 5 s delay passes without polls, so it still reads turning_on
    for _ = 1, 6 do btTick() end
    eq(bt.enabled, false, "enabled")
end)

test("bt: forget not supported points to Android Bluetooth settings", function()
    bt.forget_unsupported = true
    local _, items = newBtPlugin()
    itemNamed(items, "Paired remotes").sub_item_table_func()[1].hold_callback()
    shown[#shown].ok_callback()
    local box = shown[#shown]
    eq(box.ok_text, "Bluetooth settings", "prompt button")
    box.ok_callback()
    eq(bt.opened_settings, 1, "opened settings")
end)

test("bt: pairing a new remote turns Bluetooth on, finds it and connects", function()
    btStartOff()
    local plugin = newBtPlugin()
    plugin:findRemotes()
    runScheduled()
    local menu = lastShownMenu()
    assert(menu, "no remote list shown")
    assert(bt.scan_at ~= nil or bt.polls < bt.scan_len, "waited for the whole scan")
    eq(#menu.item_table, 2, "named, unpaired devices only")
    eq(menu.item_table[1].text, "Page Turner", "remote first")
    eq(menu.item_table[1].mandatory, "remote", "remote label")
    selectMenuItem(menu, 1)
    assert(closed[menu], "list not closed")
    eq(bt.scan_stops, 0, "btScanStop after choosing a remote") -- would cancel the pairing
    runScheduled()
    eq(lastMessage(), "Connected to Page Turner.", "message")
    eq(plugin.busy, false, "busy")
end)

test("bt: closing the remote list stops discovery", function()
    local plugin = newBtPlugin()
    plugin:findRemotes()
    runScheduled()
    lastShownMenu().close_callback()
    eq(bt.scan_stops, 1, "btScanStop calls")
end)

test("bt: no remotes found", function()
    bt.nearby = { { address = "AA:00:00:00:00:04", remote = false, appear = 1 } }
    local plugin = newBtPlugin()
    plugin:findRemotes()
    runScheduled()
    eq(lastMessage(), "No remotes found. Put your remote in pairing mode, then try again.", "message")
    eq(bt.scan_stops, 1, "btScanStop calls")
end)

test("bt: finding remotes needs location permission", function()
    wifi.locationPermission = false
    local plugin = newBtPlugin()
    plugin:findRemotes()
    runScheduled()
    assert(lastMessage():find("^Finding remotes needs location permission for the helper%."), lastMessage())
    assert(lastMessage():find("Allow location access", 1, true), "no how-to")
end)

test("bt: pairing fails when the remote is not in pairing mode", function()
    bt.nearby[1].pairing_mode = false
    local plugin = newBtPlugin()
    plugin:pairRemote(bt.nearby[1])
    runScheduled()
    eq(lastMessage(), "Could not pair with Page Turner. Put it in pairing mode and try again.", "message")
end)

test("bt: a refused pairing still stops discovery", function()
    bt.reject_pair = true
    local plugin = newBtPlugin()
    plugin:findRemotes()
    runScheduled()
    selectMenuItem(lastShownMenu(), 1)
    runScheduled()
    eq(bt.scan_stops, 1, "btScanStop calls")
    eq(bt.scan_at, nil, "still discovering")
end)

test("bt: a pairing that fails between two polls is reported at once", function()
    bt.pair_fails_at_once = true
    local plugin = newBtPlugin()
    plugin:pairRemote(bt.nearby[1])
    runScheduled()
    eq(lastMessage(), "Could not pair with Page Turner. Put it in pairing mode and try again.", "message")
    assert(bt.polls <= 2, "waited for the timeout: " .. bt.polls .. " polls")
end)

test("bt: paired but not connected at the timeout", function()
    bt.no_auto_connect = true
    local plugin = newBtPlugin()
    plugin:pairRemote(bt.nearby[1])
    runScheduled()
    eq(lastMessage(), "Paired with Page Turner. Press a button on it to connect.", "message")
end)

test("bt: on while reading turns Bluetooth on when a book opens", function()
    settings_store.nookbluetooth_while_reading = true
    btStartOff()
    local plugin = newBtPlugin(true)
    plugin:onReaderReady()
    runScheduled()
    btTick(); btTick()
    eq(bt.enabled, true, "enabled")
    eq(#shown, 0, "showed a message")
end)

test("bt: nothing happens while the option is off", function()
    btStartOff()
    local plugin = newBtPlugin(true)
    plugin:onReaderReady()
    plugin:onCloseDocument()
    runScheduled()
    eq(bt.state, "off", "state")
    eq(#queue, 0, "scheduled work")
end)

test("bt: closing a book turns Bluetooth off after a delay", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin = newBtPlugin(true)
    plugin:onCloseDocument()
    eq(bt.state, "on", "turned off at once")
    runScheduled()
    eq(now, 5, "delay")
    eq(bt.state, "turning_off", "state")
end)

test("bt: opening the next book cancels the pending turn-off", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin = newBtPlugin(true)
    plugin:onCloseDocument()
    local next_book = newBtPlugin(true) -- a new ReaderUI, a new plugin instance
    next_book:onReaderReady()
    runScheduled()
    eq(bt.state, "on", "state")
end)

test("bt: sleeping while reading turns Bluetooth off, waking turns it on", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin = newBtPlugin(true)
    bt.screen_on = false -- the Nook turns the screen off before KOReader is paused
    plugin:onRequestSuspend()
    btTick(); btTick()
    eq(bt.enabled, false, "off while asleep")
    bt.screen_on = true
    plugin:onResume()
    btTick(); btTick()
    eq(bt.enabled, true, "on after waking")
end)

test("bt: sleeping in the file browser leaves Bluetooth alone", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin = newBtPlugin(false)
    bt.screen_on = false
    plugin:onRequestSuspend()
    eq(bt.state, "on", "state")
end)

test("bt: Bluetooth switched off by hand stays off after waking", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin = newBtPlugin(true)
    btStartOff()
    bt.screen_on = false
    plugin:onRequestSuspend()
    bt.screen_on = true
    plugin:onResume()
    eq(bt.state, "off", "state")
end)

test("bt: another app opening while reading does not count as sleeping", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin, items = newBtPlugin(true)
    itemNamed(items, "Open Android Bluetooth settings").callback()
    eq(bt.opened_settings, 1, "opened settings")
    plugin:onRequestSuspend() -- KOReader goes to the background; the screen stays on
    eq(bt.state, "on", "turned off for another app")
    plugin:onResume()
    eq(bt.state, "on", "state after coming back")
    bt.screen_on = false
    plugin:onRequestSuspend() -- now a real sleep
    eq(bt.state, "turning_off", "state")
end)

test("bt: closing a book, then pairing, cancels the pending turn-off", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin = newBtPlugin(true)
    plugin:onCloseDocument()
    local browser = newBtPlugin(false) -- back in the file manager
    browser:pairRemote(bt.nearby[1])
    runScheduled()
    eq(lastMessage(), "Connected to Page Turner.", "message")
    eq(bt.state, "on", "state")
end)

test("bt: pairing in progress does not count as sleeping", function()
    settings_store.nookbluetooth_while_reading = true
    local plugin = newBtPlugin(true)
    plugin:pairRemote(bt.nearby[1])
    bt.screen_on = false -- even if the screen also went off
    plugin:onRequestSuspend() -- e.g. Android's PIN dialog
    eq(bt.state, "on", "state")
    runScheduled()
end)

test("bt: turning the option on while reading turns Bluetooth on", function()
    btStartOff()
    local _, items = newBtPlugin(true)
    itemNamed(items, "On while reading").callback()
    eq(settings_store.nookbluetooth_while_reading, true, "setting")
    eq(bt.state, "turning_on", "state")
end)

-- Power-off timer ----------------------------------------------------------

local function newPowerPlugin()
    local menu_items = {}
    local plugin = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = NookWifi })
    plugin:init()
    plugin:addToMainMenu(menu_items)
    return plugin, menu_items.nookpower
end
local function fakeTouchMenu()
    local tm = { updates = 0 }
    function tm:updateItems() self.updates = self.updates + 1 end
    return tm
end

test("power: menu shows the current timeout", function()
    local _, item = newPowerPlugin()
    eq(item.sorting_hint, "device", "menu section")
    eq(item.text_func(), "Nook power off after sleeping: Never", "text")
    eq(item.enabled_func(), true, "enabled")
    local items = item.sub_item_table_func()
    local texts = {}
    for _, it in ipairs(items) do table.insert(texts, it.text) end
    eq(table.concat(texts, ", "), "Never, 1 hour, 6 hours, 1 day, 3 days, 1 week, About this setting", "choices")
    eq(items[1].checked_func(), true, "Never checked")
    eq(items[4].checked_func(), false, "1 day not checked")
end)

test("power: choosing without permission asks to allow it, then opens the screen", function()
    local _, item = newPowerPlugin()
    local items = item.sub_item_table_func()
    items[4].callback(fakeTouchMenu()) -- 1 day
    eq(wifi.power.ms, 0, "changed without permission")
    local box = shown[#shown]
    assert(box.ok_callback, "no prompt")
    assert(box.text:find("modify system settings", 1, true), box.text)
    eq(box.ok_text, "Open", "button")
    box.ok_callback()
    eq(wifi.power.opened, 1, "settings screen opened")
end)

test("power: choosing with permission sets it and reports the value read back", function()
    wifi.power.write_allowed = true
    local _, item = newPowerPlugin()
    local items = item.sub_item_table_func()
    local tm = fakeTouchMenu()
    items[4].callback(tm) -- 1 day
    eq(wifi.power.ms, 86400000, "power_off_timeout")
    eq(lastMessage(), "The Nook will power off after sleeping for 1 day.", "message")
    eq(tm.updates, 1, "menu refreshed")
    eq(items[4].checked_func(), true, "1 day checked") -- not served from the old cache
    eq(item.text_func(), "Nook power off after sleeping: 1 day", "text")
    items[1].callback(tm) -- Never
    eq(wifi.power.ms, 0, "back to never")
    eq(lastMessage(), "The Nook will not power off by itself.", "message")
end)

test("power: a value set some other way is shown and checked", function()
    wifi.power.ms = 120000 -- e.g. over ADB
    local _, item = newPowerPlugin()
    eq(item.text_func(), "Nook power off after sleeping: 2 minutes", "text")
    local items = item.sub_item_table_func()
    local custom = items[7]
    eq(custom.text, "Custom: 2 minutes", "custom item")
    eq(custom.checked_func(), true, "custom checked")
    eq(custom.enabled_func(), false, "custom not selectable")
    eq(items[1].checked_func(), false, "Never not checked")
end)

test("power: odd values set some other way are shown as stored", function()
    for _, case in ipairs({ { 30000, "30 seconds" }, { 1000, "1 second" }, { 90 * 60000, "90 minutes" },
            { 14 * 86400000, "14 days" }, { -5, "-5 ms" } }) do
        wifi.power.ms = case[1]
        local _, item = newPowerPlugin()
        eq(item.text_func(), "Nook power off after sleeping: " .. case[2], "text for " .. case[1])
    end
end)

test("power: a reply without a value does not crash the menu or the change", function()
    wifi.power.write_allowed = true
    wifi.power_no_value = true
    local plugin, item = newPowerPlugin()
    eq(item.text_func(), "Nook power off after sleeping", "text")
    eq(item.enabled_func(), false, "enabled")
    plugin:setPowerOffTimeout(86400000)
    assert(lastMessage():find("bad_reply", 1, true), lastMessage())
end)

test("power: without the helper the menu is disabled", function()
    helper_missing = true
    local _, item = newPowerPlugin()
    eq(item.text_func(), "Nook power off after sleeping", "text")
    eq(item.enabled_func(), false, "enabled")
end)

test("power: an older helper without the timer disables the menu", function()
    wifi.power_unsupported = true
    local _, item = newPowerPlugin()
    eq(item.text_func(), "Nook power off after sleeping", "text")
    eq(item.enabled_func(), false, "enabled")
end)

test("power: an older helper reports it is out of date when choosing", function()
    local plugin = newPowerPlugin()
    wifi.power_unsupported = true
    plugin:setPowerOffTimeout(86400000)
    eq(lastMessage(), "Nook Wi-Fi Helper is out of date. Update it.", "message")
end)

-- Nook home -----------------------------------------------------------------

local function newHomePlugin()
    local menu_items = {}
    local plugin = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = NookWifi })
    plugin:init()
    plugin:addToMainMenu(menu_items)
    return plugin, menu_items.nookhome
end

test("nook home: the Tools menu item opens the Nook home", function()
    local _, item = newHomePlugin()
    eq(item.text, "Open Nook home", "text")
    eq(item.sorting_hint, "tools", "menu section")
    local before = #shown
    item.callback()
    eq(wifi.nook_home_opened, 1, "opened")
    eq(#shown, before, "showed a message on success")
end)

test("nook home: the gesture action is registered and opens it", function()
    local plugin = newHomePlugin()
    local action = registered_actions.nookhome_open
    assert(action, "no action")
    eq(action.event, "NookHomeOpen", "event")
    eq(action.general, true, "general")
    eq(plugin:onNookHomeOpen(), true, "handled")
    eq(wifi.nook_home_opened, 1, "opened")
end)

test("nook home: a missing Nook home is reported", function()
    wifi.nook_home_available = false
    local _, item = newHomePlugin()
    item.callback()
    eq(lastMessage(), "The Nook home screen is not available on this device.", "message")
end)

test("nook home: an older helper says it is out of date", function()
    wifi.nook_home_unknown = true
    local plugin = newHomePlugin()
    plugin:openNookHome()
    eq(lastMessage(), "Nook Wi-Fi Helper is out of date. Update it.", "message")
end)

test("nook home: without the helper it says to install it", function()
    helper_missing = true
    local plugin = newHomePlugin()
    plugin:openNookHome()
    eq(lastMessage(), "Nook Wi-Fi Helper is not installed.", "message")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
