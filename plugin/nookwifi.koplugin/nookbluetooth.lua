--[[--
Bluetooth page-turner remotes for the Nook, through the Nook Wi-Fi Helper's
bt* methods (see helper/.../BluetoothOps.java). Mixed into NookWifi by main.lua,
so it shares the helper client, the busy flag, progress messages and polling.

Verified in Bluetooth Stage 0 (AGENTS.md): on/off, paired devices, discovery,
pairing (Android connects the remote by itself once paired) and forgetting all
work from the helper, with no Android settings screen and no popup for the
8BitDo Micro. A paired remote reconnects when one of its buttons is pressed.

@module nookbluetooth
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local Helper = require("nookwifihelper")

-- On and off each took about 1 s on the Nook.
local SWITCH_TIMEOUT_S = 10
-- Discovery took about 14 s. A remote in pairing mode showed up within 0.5 s, so
-- the list opens this long after the first likely remote, without waiting it out.
local SCAN_TIMEOUT_S = 20
local REMOTE_GRACE_S = 2
-- Pairing took about 3 s, and the remote connected 0.3 s after that.
local PAIR_TIMEOUT_S = 30
-- Forgetting took under 1 s. Android queues the removal, so the request being
-- accepted does not mean it happened.
local FORGET_TIMEOUT_S = 10
-- After a book closes, wait this long before turning Bluetooth off, so opening
-- the next book straight away does not switch it off and on again.
local CLOSE_DELAY_S = 5
-- After Bluetooth turns on, watch this long for a remote to connect, so the
-- menu and the user hear about it (the 8BitDo connected about 35 s after
-- Bluetooth came on in one test: whenever its button was pressed).
local CONNECT_WATCH_S = 60
local CONNECT_WATCH_INTERVAL_S = 1
local STATE_CACHE_S = 1

local WHILE_READING = "nookbluetooth_while_reading"

-- Shared by all plugin instances (KOReader creates one for the file manager and
-- one per opened book), because a book's instance is gone when its timer fires.
local shared = {
    -- Scheduled "turn off" after a book closed.
    pending_off = nil,
    -- Bluetooth was turned off because the Nook went to sleep while reading.
    off_for_sleep = false,
}

local function whileReading()
    return G_reader_settings:isTrue(WHILE_READING)
end

return function(NookWifi, errorText)

-- One table for all instances (offline tests reset it between cases).
NookWifi.bt_shared = shared

-- Bluetooth-specific messages, then the plugin's general ones.
local function btErrorText(reply, err)
    local code = reply and reply.error
    if code == "bt_unavailable" then
        return _("This device has no Bluetooth.")
    elseif code == "bt_disabled" then
        return _("Bluetooth is off.")
    elseif code == "request_rejected" then
        return _("Android rejected the Bluetooth request.")
    elseif code == "already_paired" then
        return _("That remote is already paired.")
    elseif code == "not_paired" then
        return _("That remote is no longer paired.")
    elseif code == "not_supported" or code == "settings_unavailable" then
        return _("Not supported on this device. Use Android Bluetooth settings.")
    elseif code == "location_permission_needed" then
        local text = errorText(reply, err):gsub("^[^\n]*", _("Finding remotes needs location permission for the helper."), 1)
        return text
    end
    return errorText(reply, err)
end

local function call(method, arg)
    local reply, err = Helper.call(method, arg)
    if not reply or not reply.ok then return nil, btErrorText(reply, err), reply end
    return reply
end

local function deviceName(dev)
    return dev.name or dev.address
end

-- Returns the btState reply, or nil and a message.
function NookWifi:btState(fresh)
    if not fresh and self.bt_cached and time.to_s(time.since(self.bt_cached_at)) < STATE_CACHE_S then
        return self.bt_cached
    end
    local reply, msg = call("btState")
    self.bt_cached, self.bt_cached_at = reply, time.now()
    return reply, msg
end

function NookWifi:btPaired(fresh)
    if not fresh and self.bt_paired and time.to_s(time.since(self.bt_paired_at)) < STATE_CACHE_S then
        return self.bt_paired
    end
    local reply, msg = call("btPaired")
    self.bt_paired, self.bt_paired_at = reply, time.now()
    return reply, msg
end

function NookWifi:btStatusText()
    local state, msg = self:btState()
    if not state then return msg end
    if not state.available then return _("Not available") end
    local s = state.bluetoothState
    if s == "turning_on" then return _("Turning on…") end
    if s == "turning_off" then return _("Turning off…") end
    if s == "off" then return _("Off") end
    if s ~= "on" then return _("Unknown") end
    local paired = self:btPaired()
    local names = {}
    for __, dev in ipairs(paired and paired.devices or {}) do
        if dev.connection == "connected" then table.insert(names, deviceName(dev)) end
    end
    if #names > 0 then return T(_("On, %1 connected"), table.concat(names, ", ")) end
    if not state.hidReady then return _("On") end
    return _("On, no remote connected")
end

-- Quiet switch for the automatic "while reading" behaviour: no message, no
-- waiting; failures are only logged.
-- Whether Bluetooth is at, or already heading to, on (or off). "enabled" alone
-- is not enough: it is false while turning on, so a turn-off then would be
-- skipped and Bluetooth would finish turning on, e.g. while the Nook sleeps.
local function headingTo(state, on)
    local s = state.bluetoothState
    if on then return s == "on" or s == "turning_on" end
    return s == "off" or s == "turning_off"
end

local function switchQuietly(on, why)
    local state = call("btState")
    if not state or not state.available or headingTo(state, on) then return end
    local reply, msg = call("btSetEnabled", on and "true" or "false")
    if reply then
        logger.info("NookWifi: Bluetooth", on and "on" or "off", "(" .. why .. ")")
    else
        logger.warn("NookWifi: could not switch Bluetooth", on and "on" or "off", "(" .. why .. "):", msg)
    end
end

local function cancelPendingOff()
    if shared.pending_off then
        UIManager:unschedule(shared.pending_off)
        shared.pending_off = nil
    end
end

-- After Bluetooth turned on: tells the user once a paired remote connects, and
-- refreshes the open menu, whose status line is otherwise only read when drawn.
-- Stops when a remote connects, Bluetooth goes off, or after CONNECT_WATCH_S.
function NookWifi:watchForRemote(touchmenu_instance)
    local started = time.now()
    local function tick()
        local paired = call("btPaired")
        if not paired or not paired.enabled then return end
        for __, dev in ipairs(paired.devices or {}) do
            if dev.connection == "connected" then
                self.bt_cached, self.bt_paired = nil, nil
                UIManager:show(InfoMessage:new{ text = T(_("%1 connected."), deviceName(dev)), timeout = 2 })
                -- Only if the menu is still open: refreshing a closed TouchMenu
                -- makes KOReader repaint the whole screen (an e-ink flash).
                if touchmenu_instance and UIManager:isWidgetShown(touchmenu_instance.show_parent) then
                    touchmenu_instance:updateItems()
                end
                return
            end
        end
        if time.to_s(time.since(started)) < CONNECT_WATCH_S then
            UIManager:scheduleIn(CONNECT_WATCH_INTERVAL_S, tick)
        end
    end
    UIManager:scheduleIn(CONNECT_WATCH_INTERVAL_S, tick)
end

-- Switches Bluetooth and reports once it has really changed.
function NookWifi:setBluetooth(on, touchmenu_instance)
    if self.busy then return end
    -- The user decides now; a turn-off still pending from a closed book must not
    -- undo it (or cut into a pairing started right after closing a book).
    cancelPendingOff()
    local reply, msg = call("btSetEnabled", on and "true" or "false")
    if not reply then
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end
    local finish = self:beginOperation(on and _("Turning Bluetooth on…") or _("Turning Bluetooth off…"),
        touchmenu_instance)
    local function fetch() return call("btState") end
    self:pollState(SWITCH_TIMEOUT_S, finish, function(s)
        if s.enabled ~= on or s.bluetoothState ~= (on and "on" or "off") then return false end
        self.bt_cached, self.bt_paired = nil, nil
        finish(on and _("Bluetooth on. Press a button on your remote to connect it.") or _("Bluetooth off."))
        if on then self:watchForRemote(touchmenu_instance) end
        return true
    end, function()
        finish(on and T(_("Bluetooth did not turn on within %1 seconds."), SWITCH_TIMEOUT_S)
            or T(_("Bluetooth did not turn off within %1 seconds."), SWITCH_TIMEOUT_S))
    end, fetch)
end

-- Turns Bluetooth on if needed, then calls next_step once it reports on.
function NookWifi:ensureBluetooth(finish, next_step)
    local state, msg = call("btState")
    if not state then return finish(msg) end
    if not state.available then return finish(_("This device has no Bluetooth.")) end
    if state.enabled then return next_step() end
    local reply, err = call("btSetEnabled", "true")
    if not reply then return finish(err) end
    self:pollState(SWITCH_TIMEOUT_S, finish, function(s)
        if not s.enabled then return false end
        next_step()
        return true
    end, function()
        finish(T(_("Bluetooth did not turn on within %1 seconds."), SWITCH_TIMEOUT_S))
    end, function() return call("btState") end)
end

function NookWifi:pairedRemotesMenu()
    local reply, msg = self:btPaired(true)
    if not reply then return { { text = msg, enabled = false } } end
    if not reply.enabled then return { { text = _("Turn on Bluetooth to see paired remotes."), enabled = false } } end
    local devices = reply.devices or {}
    if #devices == 0 then return { { text = _("No paired remotes"), enabled = false } } end
    table.sort(devices, function(a, b)
        if (a.connection == "connected") ~= (b.connection == "connected") then return a.connection == "connected" end
        if a.remote ~= b.remote then return a.remote end
        return deviceName(a) < deviceName(b)
    end)
    local items = {}
    for __, dev in ipairs(devices) do
        local label = deviceName(dev)
        if dev.connection == "connected" then label = T(_("%1 · connected"), label) end
        table.insert(items, {
            text = label,
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = dev.connection == "connected" and T(_("%1 is connected."), deviceName(dev))
                        or T(_("%1 is paired. Press a button on it to connect."), deviceName(dev)),
                })
            end,
            hold_callback = function(touchmenu_instance) self:confirmForget(dev, touchmenu_instance) end,
        })
    end
    return items
end

function NookWifi:confirmForget(dev, touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = T(_("Forget %1? You will need to pair it again to use it."), deviceName(dev)),
        ok_text = _("Forget"),
        ok_callback = function() self:forgetRemote(dev, touchmenu_instance) end,
    })
end

-- Reports success only once Android says the remote is no longer paired.
function NookWifi:forgetRemote(dev, touchmenu_instance)
    if self.busy then return end
    local name = deviceName(dev)
    local reply, msg, raw = call("btForget", dev.address)
    self.bt_paired = nil
    if not reply then
        if raw and raw.error == "not_supported" then
            self:showBluetoothSettingsPrompt(msg)
        else
            UIManager:show(InfoMessage:new{ text = msg })
        end
        return
    end
    local finish = self:beginOperation(T(_("Forgetting %1…"), name), touchmenu_instance)
    self:pollState(FORGET_TIMEOUT_S, finish, function(r)
        -- Not bond == "none": Android 8.1 also reports that when the Bluetooth
        -- service is down or the query fails. The helper sets forgotten from
        -- Android's own bond-removed broadcast.
        if not (r.device or {}).forgotten then return false end
        self.bt_paired = nil
        finish(T(_("Forgot %1."), name))
        -- The paired list was built when it opened and still shows the remote;
        -- go back up to the Bluetooth menu, whose status is redrawn.
        if touchmenu_instance and UIManager:isWidgetShown(touchmenu_instance.show_parent) then
            touchmenu_instance:backToUpperMenu()
        end
        return true
    end, function()
        self.bt_paired = nil
        finish()
        self:showBluetoothSettingsPrompt(T(_("Could not forget %1. Try again, or use Android Bluetooth settings."),
            name))
    end, function() return call("btDevice", dev.address) end)
end

function NookWifi:showBluetoothSettingsPrompt(text)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Bluetooth settings"),
        ok_callback = function() self:openBluetoothSettings() end,
    })
end

-- Stock Android settings, opened by the helper (never the Nook's own screen).
function NookWifi:openBluetoothSettings()
    local reply, msg = call("btOpenSettings")
    if not reply then
        UIManager:show(InfoMessage:new{ text = msg })
    end
end

-- Likely remotes first, then by name.
local function sortFound(devices)
    table.sort(devices, function(a, b)
        if a.remote ~= b.remote then return a.remote end
        return deviceName(a) < deviceName(b)
    end)
end

function NookWifi:findRemotes(touchmenu_instance)
    if self.busy then return end
    cancelPendingOff()
    local finish = self:beginOperation(_("Looking for remotes… Put your remote in pairing mode."), touchmenu_instance)
    self:ensureBluetooth(finish, function()
        local reply, msg = call("btScan")
        if not reply then return finish(msg) end
        local remote_since
        local function show(results)
            finish()
            self:showFoundRemotes(results.devices or {}, touchmenu_instance)
        end
        self:pollState(SCAN_TIMEOUT_S, finish, function(results)
            if results.finished then
                show(results)
                return true
            end
            for __, dev in ipairs(results.devices or {}) do
                if dev.remote and dev.bond ~= "bonded" then
                    remote_since = remote_since or time.now()
                end
            end
            if remote_since and time.to_s(time.since(remote_since)) >= REMOTE_GRACE_S then
                show(results)
                return true
            end
            return false
        end, show, function() return call("btScanResults") end)
    end)
end

function NookWifi:showFoundRemotes(devices, touchmenu_instance)
    local new = {}
    for __, dev in ipairs(devices) do
        if dev.bond ~= "bonded" then table.insert(new, dev) end
    end
    if #new == 0 then
        call("btScanStop")
        UIManager:show(InfoMessage:new{
            text = _("No remotes found. Put your remote in pairing mode, then try again."),
        })
        return
    end
    sortFound(new)
    local menu
    local items = {}
    for __, dev in ipairs(new) do
        table.insert(items, {
            text = deviceName(dev),
            mandatory = dev.remote and _("remote") or nil,
            callback = function()
                UIManager:close(menu)
                self:pairRemote(dev, touchmenu_instance)
            end,
        })
    end
    menu = Menu:new{
        title = _("Choose your remote"),
        item_table = items,
        covers_fullscreen = true,
        is_popout = false,
        -- Back or close: stop discovery. Choosing a remote closes the menu
        -- directly; btPair stops discovery itself.
        close_callback = function()
            call("btScanStop")
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

function NookWifi:pairRemote(dev, touchmenu_instance)
    if self.busy then return end
    cancelPendingOff()
    local name = deviceName(dev)
    local finish = self:beginOperation(T(_("Pairing with %1…"), name), touchmenu_instance)
    local reply, msg = call("btPair", dev.address)
    if not reply then return finish(msg) end
    local bonding_seen = false
    self:pollState(PAIR_TIMEOUT_S, finish, function(r)
        local d = r.device or {}
        if d.bond == "bonding" then bonding_seen = true end
        if d.bond == "bonded" and d.connection == "connected" then
            self.bt_paired = nil
            finish(T(_("Connected to %1."), name))
            return true
        end
        if d.bond == "none" and bonding_seen then
            finish(T(_("Could not pair with %1. Put it in pairing mode and try again."), name))
            return true
        end
        return false
    end, function(r)
        local d = r.device or {}
        self.bt_paired = nil
        if d.bond == "bonded" then
            finish(T(_("Paired with %1. Press a button on it to connect."), name))
        else
            finish(T(_("Could not pair with %1. Put it in pairing mode and try again."), name))
        end
    end, function() return call("btDevice", dev.address) end)
end

function NookWifi:addBluetoothMenu(menu_items)
    local function available()
        local state = self:btState()
        return not self.busy and state ~= nil and state.available
    end
    -- Checked while on or turning on, so a tap during either switches it off.
    local function isOn()
        local state = self:btState()
        return state ~= nil and state.available and headingTo(state, true)
    end
    menu_items.nookbluetooth = {
        text = _("Nook Bluetooth"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function() return T(_("Status: %1"), self:btStatusText()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self.bt_cached, self.bt_paired = nil, nil
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Bluetooth"),
                checked_func = isOn,
                enabled_func = available,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local state = self:btState(true)
                    if state then self:setBluetooth(not headingTo(state, true), touchmenu_instance) end
                end,
            },
            {
                text = _("On while reading"),
                help_text = _("Turns Bluetooth on when a book opens, and off when it closes or the Nook sleeps. "
                    .. "Press a button on your remote to reconnect it."),
                checked_func = whileReading,
                keep_menu_open = true,
                callback = function()
                    G_reader_settings:flipNilOrFalse(WHILE_READING)
                    if whileReading() and self.ui and self.ui.document then
                        switchQuietly(true, "option turned on while reading")
                    end
                end,
                separator = true,
            },
            {
                text = _("Paired remotes"),
                enabled_func = available,
                sub_item_table_func = function() return self:pairedRemotesMenu() end,
            },
            {
                text = _("Pair a new remote…"),
                enabled_func = available,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:findRemotes(touchmenu_instance) end,
                separator = true,
            },
            {
                text = _("Open Android Bluetooth settings"),
                callback = function() self:openBluetoothSettings() end,
            },
        },
    }
end

function NookWifi:registerBluetoothActions()
    Dispatcher:registerAction("nookbluetooth_toggle", {
        category = "none",
        event = "NookBluetoothToggle",
        title = _("Toggle Bluetooth"),
        general = true,
    })
end

-- Gesture or key action.
function NookWifi:onNookBluetoothToggle()
    local state, msg = self:btState(true)
    if not state then
        UIManager:show(InfoMessage:new{ text = msg })
    elseif state.available then
        -- While turning on, a toggle means "off" (and while turning off, "on").
        self:setBluetooth(not headingTo(state, true))
    end
    return true
end

-- "On while reading". These events reach the instance belonging to the open
-- book. On Android, KOReader sends RequestSuspend whenever it goes to the
-- background and Resume when it comes back: when the Nook sleeps, but also when
-- another app opens (Android Wi-Fi or Bluetooth settings, a dictionary, a link).
-- Only sleep should turn Bluetooth off, so the helper's screenOn decides.

function NookWifi:onReaderReady()
    if not whileReading() then return end
    cancelPendingOff()
    shared.off_for_sleep = false
    switchQuietly(true, "book opened")
end

function NookWifi:onCloseDocument()
    if not whileReading() then return end
    cancelPendingOff()
    shared.pending_off = function()
        shared.pending_off = nil
        if whileReading() then switchQuietly(false, "book closed") end
    end
    UIManager:scheduleIn(CLOSE_DELAY_S, shared.pending_off)
end

function NookWifi:onRequestSuspend()
    -- Not while pairing: a remote that needs a PIN brings up Android's pairing
    -- dialog, which sends KOReader to the background too.
    if not whileReading() or self.busy or not (self.ui and self.ui.document) then return end
    local state = call("btState")
    -- screenOn is missing only from a helper too old for Bluetooth anyway.
    if state and state.available and not headingTo(state, false) and state.screenOn == false then
        shared.off_for_sleep = true
        switchQuietly(false, "sleeping")
    end
end

function NookWifi:onResume()
    if not whileReading() or not shared.off_for_sleep or not (self.ui and self.ui.document) then return end
    shared.off_for_sleep = false
    switchQuietly(true, "woke up")
end

end
