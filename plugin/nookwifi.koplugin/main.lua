--[[--
Wi-Fi controls for the Nook GlowLight 4 Plus, backed by the Nook Wi-Fi Helper app.

@module koplugin.NookWifi
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

if not Device:isAndroid() then
    return { disabled = true }
end

local Helper = require("nookwifihelper")
local Network = require("nookwifinetwork")

local POLL_INTERVAL_S = 0.5
local STATE_TIMEOUT_S = 20
local CONNECT_TIMEOUT_S = 20
-- A scan took about 1 s on the Nook; past this, show whatever results are cached.
local SCAN_TIMEOUT_S = 10
-- How long a connection to some other network must last before awaitNetwork
-- calls it a fallback. Right after Wi-Fi turns on, Android may autojoin another
-- saved network briefly before switching to the requested one.
local FALLBACK_GRACE_S = 4
-- How long an authentication failure must persist without the requested network
-- connecting before awaitNetwork reports a wrong password. The helper keeps the
-- flag until the next attempt, and Android may retry and succeed after a
-- transient failure.
local AUTH_GRACE_S = 3
-- Menu text and checkbox funcs run together on each redraw; reuse one reply.
local STATE_CACHE_S = 1

local PLUGIN_VERSION = "1.0.3"
local GRANT_COMMAND = "adb shell pm grant dev.nookwifi.helper android.permission.ACCESS_COARSE_LOCATION"

-- How to grant the helper's location permission: its setup screen, or ADB.
local function grantHowTo()
    return T(_("Open the Nook Wi-Fi Helper app from your launcher and tap \"Allow location access\". Or, over USB:\n%1"),
        GRANT_COMMAND)
end

local CONNECTING = {
    connecting = true,
    authenticating = true,
    obtaining_ipaddr = true,
    verifying_poor_link = true,
    captive_portal_check = true,
}

-- Security types the helper can join; the rest get a "not supported" message.
local JOINABLE = { open = true, wpa_psk = true }
local SECURITY_NAMES = {
    sae = "WPA3",
    owe = "Enhanced Open (OWE)",
    eap = "WPA Enterprise (802.1X)",
    wep = "WEP",
}

local NookWifi = WidgetContainer:extend{
    name = "nookwifi",
    is_doc_only = false,
}

function NookWifi:init()
    Network.install()
    self.ui.menu:registerToMainMenu(self)
end

-- Turns a failed call (reply with ok=false, or nil plus an error code) into a short message.
local function errorText(reply, err)
    if err == "helper_not_installed" then
        return _("Nook Wi-Fi Helper is not installed.")
    elseif err == "protocol_mismatch" then
        return _("Nook Wi-Fi Helper and this plugin are different versions. Update both.")
    elseif not reply then
        return T(_("Could not reach Nook Wi-Fi Helper (%1)."), err)
    elseif reply.error == "caller_not_allowed" then
        return _("Nook Wi-Fi Helper does not accept requests from this KOReader build.")
    elseif reply.error == "request_rejected" then
        return _("Android rejected the Wi-Fi request.")
    elseif reply.error == "wifi_disabled" then
        return _("Wi-Fi is off.")
    elseif reply.error == "unknown_network" then
        return _("That network is no longer saved.")
    elseif reply.error == "unknown_method" then
        return _("Nook Wi-Fi Helper is out of date. Update it.")
    elseif reply.error == "location_permission_needed" then
        return _("Scanning needs location permission for the helper.") .. "\n\n" .. grantHowTo()
    elseif reply.error == "invalid_password" then
        return _("Wi-Fi passwords must be 8 to 63 characters.")
    elseif reply.error == "unsupported_security" then
        return _("This network's security type is not supported.")
    end
    return T(_("Nook Wi-Fi Helper reported an error (%1)."), tostring(reply.error))
end

-- Returns the helper's getState reply, or nil and a message.
function NookWifi:getState(fresh)
    if not fresh and self.cached_state and time.to_s(time.since(self.cached_at)) < STATE_CACHE_S then
        return self.cached_state
    end
    local reply, err = Helper.call("getState")
    if not reply or not reply.ok then
        self.cached_state = nil
        return nil, errorText(reply, err)
    end
    self.cached_state, self.cached_at = reply, time.now()
    return reply
end

local function networkName(state)
    if state.ssid then return state.ssid end
    if not state.locationPermission then return _("(name hidden)") end
    return _("(unknown network)")
end

local function connectedText(state)
    if state.ssid then return T(_("Connected to %1"), state.ssid) end
    return T(_("Connected %1"), networkName(state))
end

local function statusText(state)
    if state.wifiState == "enabling" then
        return _("Turning on…")
    elseif state.wifiState == "disabling" then
        return _("Turning off…")
    elseif state.wifiState == "disabled" then
        return _("Off")
    elseif state.wifiState ~= "enabled" then
        return _("Unknown")
    elseif state.connection == "connected" then
        return connectedText(state)
    elseif CONNECTING[state.connection] then
        return _("On, connecting…")
    end
    return _("On, not connected")
end

function NookWifi:addToMainMenu(menu_items)
    local function available()
        return not self.busy and self:getState() ~= nil
    end
    menu_items.nookwifi = {
        text = _("Nook Wi-Fi"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function()
                    local state, msg = self:getState()
                    return T(_("Status: %1"), state and statusText(state) or msg)
                end,
                keep_menu_open = true,
                callback = function() self:showDetails() end,
            },
            {
                text = _("Wi-Fi"),
                checked_func = function()
                    local state = self:getState()
                    return state ~= nil and state.enabled
                end,
                enabled_func = available,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local state = self:getState(true)
                    if state then
                        self:setWifi(not state.enabled, touchmenu_instance)
                    end
                end,
            },
            {
                text = _("Reconnect"),
                enabled_func = available,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:reconnect(touchmenu_instance) end,
            },
            {
                text = _("Scan for networks…"),
                enabled_func = available,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:scanNetworks(touchmenu_instance) end,
            },
            {
                text = _("Saved networks"),
                enabled_func = available,
                sub_item_table_func = function() return self:savedNetworksMenu() end,
                separator = true,
            },
            {
                text = _("Open Android Wi-Fi settings"),
                callback = function() require("android").openWifiSettings() end,
            },
            {
                text = _("Helper info"),
                keep_menu_open = true,
                callback = function() self:showHelperInfo() end,
            },
        },
    }
end

function NookWifi:showDetails()
    local state, msg = self:getState(true)
    if not state then
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end
    local lines = { T(_("Status: %1"), statusText(state)) }
    if state.connection == "connected" then
        table.insert(lines, T(_("Network: %1"), networkName(state)))
        table.insert(lines, T(_("Signal: %1/4 (%2 dBm)"), state.signalLevel, state.rssi))
        table.insert(lines, T(_("IP address: %1"), state.ip))
        table.insert(lines, T(_("Link speed: %1 Mbps"), state.linkMbps))
    end
    if not state.locationPermission then
        table.insert(lines, "")
        table.insert(lines, _("The helper needs location permission to show network names.") .. "\n" .. grantHowTo())
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function NookWifi:showHelperInfo()
    local reply, err = Helper.call("ping")
    local text
    if not reply or not reply.ok then
        text = errorText(reply, err)
    else
        text = T(_("Nook Wi-Fi Helper %1 is installed and responding.\nNook Wi-Fi plugin %2."),
            reply.versionName, PLUGIN_VERSION)
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- Saved networks, current first, then strongest signal, then by name.
-- Signal is shown only when known: the current network's comes from the live
-- connection; others come from Android's last scan. No signal does not mean
-- out of range: while connected, Android's background scans cover only some
-- channels and replace the cached results (seen on the Nook).
function NookWifi:savedNetworksMenu()
    local reply, err = Helper.call("listSaved")
    if not reply or not reply.ok then
        local text = reply and reply.error == "wifi_disabled"
            and _("Turn on Wi-Fi to see saved networks.") or errorText(reply, err)
        return { { text = text, enabled = false } }
    end
    local networks = reply.networks or {}
    if #networks == 0 then
        return { { text = _("No saved networks"), enabled = false } }
    end
    local current = self:getState(true)
    if current and current.connection == "connected" then
        for __, net in ipairs(networks) do
            if net.networkId == current.networkId then net.signalLevel = current.signalLevel end
        end
    end
    table.sort(networks, function(a, b)
        if (a.status == "current") ~= (b.status == "current") then return a.status == "current" end
        local la, lb = a.signalLevel or -1, b.signalLevel or -1
        if la ~= lb then return la > lb end
        return (a.ssid or "") < (b.ssid or "")
    end)

    local items = {}
    -- Not `_`: that would shadow gettext for the rest of the loop body.
    for __, net in ipairs(networks) do
        local label = net.ssid or _("(hidden network)")
        if net.signalLevel then
            label = T(_("%1 · signal %2/4"), label, net.signalLevel)
        end
        table.insert(items, {
            text = label,
            radio = true,
            checked_func = function()
                local state = self:getState()
                return state ~= nil and state.connection == "connected" and state.networkId == net.networkId
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:connectSaved(net, touchmenu_instance) end,
        })
    end
    return items
end

-- On this Nook's firmware the helper can add networks, start connections, and
-- remove networks it created itself, but cannot change any saved network
-- ("does not have permission to update configuration") or remove ones saved by
-- the Nook or Android settings (verified in logcat). So a saved network whose
-- password no longer works must be forgotten in Android's settings.
local function showRemoveInSettings(name, lead_text)
    UIManager:show(ConfirmBox:new{
        text = lead_text .. "\n\n" .. T(_("Nook Wi-Fi cannot change saved passwords. " ..
            "Forget %1 in Android Wi-Fi settings, then join it again."), name),
        ok_text = _("Wi-Fi settings"),
        ok_callback = function() require("android").openWifiSettings() end,
    })
end

-- Starts a Wi-Fi operation: marks the plugin busy and shows progress_text.
-- Returns finish(text, event_name), which ends the operation, shows text (if
-- any), and broadcasts event_name (if any) so KOReader and other plugins (e.g.
-- sync) see the change just as if NetworkMgr had made it.
function NookWifi:beginOperation(progress_text, touchmenu_instance)
    self.busy = true
    local progress = InfoMessage:new{ text = progress_text }
    UIManager:show(progress)
    return function(text, event_name)
        self.busy = false
        self.cached_state = nil
        UIManager:close(progress)
        NetworkMgr:queryNetworkState()
        if event_name then
            UIManager:broadcastEvent(Event:new(event_name))
        end
        if text then
            UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
        end
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end
end

-- Calls step(reply) every POLL_INTERVAL_S until it returns true. After
-- timeout_s it calls on_timeout(last_reply); a helper failure ends the
-- operation through finish. fetch() returns the reply to check, or nil and a
-- message; it defaults to a fresh getState.
function NookWifi:pollState(timeout_s, finish, step, on_timeout, fetch)
    fetch = fetch or function() return self:getState(true) end
    local started = time.now()
    local function tick()
        local reply, msg = fetch()
        if not reply then return finish(msg) end
        if step(reply) then return end
        if time.to_s(time.since(started)) >= timeout_s then return on_timeout(reply) end
        UIManager:scheduleIn(POLL_INTERVAL_S, tick)
    end
    UIManager:scheduleIn(POLL_INTERVAL_S, tick)
end

-- Turns Wi-Fi on if needed, then calls next_step once it reports enabled.
function NookWifi:ensureEnabled(finish, next_step)
    local state, msg = self:getState(true)
    if not state then return finish(msg) end
    if state.enabled then return next_step() end
    local reply, err = Helper.call("setEnabled", "true")
    if not reply or not reply.ok then return finish(errorText(reply, err)) end
    UIManager:broadcastEvent(Event:new("NetworkConnecting"))
    self:pollState(STATE_TIMEOUT_S, finish, function(s)
        if s.wifiState ~= "enabled" then return false end
        next_step()
        return true
    end, function()
        finish(T(_("Wi-Fi did not turn on within %1 seconds."), STATE_TIMEOUT_S))
    end)
end

-- Waits for any connection and reports it.
function NookWifi:waitForConnection(finish)
    self:pollState(CONNECT_TIMEOUT_S, finish, function(s)
        if s.connection ~= "connected" then return false end
        finish(T(_("Wi-Fi is on. %1."), connectedText(s)), "NetworkConnected")
        return true
    end, function()
        finish(_("Wi-Fi is on but not connected to a network."))
    end)
end

-- Waits for a connection to networkId after connectSaved or join. Success goes
-- to finish; failures go to fail(text, reason), reason being "auth" for a wrong
-- password, so callers can clean up or explain first.
function NookWifi:awaitNetwork(finish, fail, network_id, name)
    -- If the network is unreachable or rejects the password, Android drops the
    -- current connection and falls back to another saved network within seconds
    -- (seen on the Nook). Report that once the other connection has lasted
    -- FALLBACK_GRACE_S, instead of waiting out the whole timeout.
    local dropped = false
    local elsewhere_since, auth_failed_since
    -- Helper errors go to fail too, so join still removes the network it created.
    self:pollState(CONNECT_TIMEOUT_S, fail, function(s)
        -- Success wins over any authentication failure recorded on the way.
        if s.connection == "connected" and s.networkId == network_id then
            finish(T(_("Connected to %1."), name), "NetworkConnected")
            return true
        end
        -- authFailedNetworkId is -1 when Android had already cleared the network;
        -- only a failure known to be for another network is ignored.
        local failed_id = s.authFailedNetworkId
        if s.authFailed and (failed_id == nil or failed_id < 0 or failed_id == network_id) then
            auth_failed_since = auth_failed_since or time.now()
            if time.to_s(time.since(auth_failed_since)) >= AUTH_GRACE_S then
                fail(T(_("Wrong password for %1."), name), "auth")
                return true
            end
        end
        if s.connection ~= "connected" then
            dropped, elsewhere_since = true, nil
            return false
        end
        if not dropped then return false end
        elsewhere_since = elsewhere_since or time.now()
        if time.to_s(time.since(elsewhere_since)) >= FALLBACK_GRACE_S then
            fail(T(_("Could not connect to %1. %2 instead."), name, connectedText(s)))
            return true
        end
        return false
    end, function(s)
        local text = T(_("Could not connect to %1. It may be out of range."), name)
        if s.connection == "connected" then
            text = text .. " " .. T(_("%1."), connectedText(s))
        end
        fail(text)
    end)
end

-- Each operation below reports success only once Wi-Fi actually reaches the
-- requested state, not when Android accepts the request.

function NookWifi:setWifi(on, touchmenu_instance)
    if self.busy then return end
    if on then
        local finish = self:beginOperation(_("Turning Wi-Fi on…"), touchmenu_instance)
        self:ensureEnabled(finish, function() self:waitForConnection(finish) end)
        return
    end

    local reply, err = Helper.call("setEnabled", "false")
    if not reply or not reply.ok then
        UIManager:show(InfoMessage:new{ text = errorText(reply, err) })
        return
    end
    local finish = self:beginOperation(_("Turning Wi-Fi off…"), touchmenu_instance)
    UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
    self:pollState(STATE_TIMEOUT_S, finish, function(s)
        if s.wifiState ~= "disabled" then return false end
        finish(_("Wi-Fi is off."), "NetworkDisconnected")
        return true
    end, function()
        finish(T(_("Wi-Fi did not turn off within %1 seconds."), STATE_TIMEOUT_S))
    end)
end

function NookWifi:reconnect(touchmenu_instance)
    if self.busy then return end
    local state = self:getState(true)
    if state and not state.enabled then
        return self:setWifi(true, touchmenu_instance)
    end
    local finish = self:beginOperation(_("Reconnecting…"), touchmenu_instance)
    local reply, err = Helper.call("reconnect")
    if not reply or not reply.ok then return finish(errorText(reply, err)) end
    self:waitForConnection(finish)
end

-- Connects to a saved network inside an operation that is already running.
function NookWifi:connectSavedStep(finish, network_id, name)
    local reply, err = Helper.call("connectSaved", tostring(network_id))
    if not reply or not reply.ok then return finish(errorText(reply, err)) end
    self:awaitNetwork(finish, function(text, reason)
        if reason ~= "auth" then return finish(text) end
        finish()
        showRemoveInSettings(name, T(_("The saved password for %1 does not work."), name))
    end, network_id, name)
end

function NookWifi:connectSaved(net, touchmenu_instance)
    if self.busy then return end
    local name = net.ssid or _("(hidden network)")
    local finish = self:beginOperation(T(_("Connecting to %1…"), name), touchmenu_instance)
    self:ensureEnabled(finish, function() self:connectSavedStep(finish, net.networkId, name) end)
end

-- Scanning and joining -------------------------------------------------------

function NookWifi:scanNetworks(touchmenu_instance)
    if self.busy then return end
    local state = self:getState(true)
    if state and not state.locationPermission then
        UIManager:show(InfoMessage:new{ text = errorText({ error = "location_permission_needed" }) })
        return
    end
    local finish = self:beginOperation(_("Scanning for networks…"), touchmenu_instance)
    local function fetchResults()
        local reply, err = Helper.call("scanResults")
        if reply and reply.ok then return reply end
        return nil, errorText(reply, err)
    end
    local function show(results)
        finish()
        self:showScanResults(results, touchmenu_instance)
    end
    self:ensureEnabled(finish, function()
        local reply, err = Helper.call("scan")
        if not reply or not reply.ok then return finish(errorText(reply, err)) end
        self:pollState(SCAN_TIMEOUT_S, finish, function(results)
            if not results.fresh then return false end
            show(results)
            return true
        end, show, fetchResults)
    end)
end

-- Current network first, then strongest signal, then by name.
local function sortNetworks(networks)
    table.sort(networks, function(a, b)
        if a.current ~= b.current then return a.current end
        if a.signalLevel ~= b.signalLevel then return a.signalLevel > b.signalLevel end
        return a.ssid < b.ssid
    end)
end

local function scanLabel(net)
    local parts = { T(_("%1/4"), net.signalLevel) }
    if net.current then
        table.insert(parts, _("connected"))
    elseif net.savedNetworkId then
        table.insert(parts, _("saved"))
    end
    if net.security == "open" then
        table.insert(parts, _("open"))
    elseif not JOINABLE[net.security] then
        table.insert(parts, _("not supported"))
    end
    return table.concat(parts, " · ")
end

function NookWifi:showScanResults(results, touchmenu_instance)
    local networks = results.networks or {}
    if #networks == 0 then
        UIManager:show(InfoMessage:new{ text = _("No networks found.") })
        return
    end
    sortNetworks(networks)
    local items = {}
    for __, net in ipairs(networks) do
        table.insert(items, {
            text = net.ssid,
            mandatory = scanLabel(net),
            callback = function() self:chooseScanned(net, touchmenu_instance) end,
        })
    end
    local menu
    menu = Menu:new{
        title = _("Wi-Fi networks"),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function NookWifi:chooseScanned(net, touchmenu_instance)
    -- The live state, not net.current: that flag is from when the list was built.
    local state = self:getState(true)
    local connected_here = state and state.connection == "connected"
        and net.savedNetworkId ~= nil and state.networkId == net.savedNetworkId
    if connected_here then
        UIManager:show(InfoMessage:new{ text = T(_("Already connected to %1."), net.ssid), timeout = 3 })
    elseif net.savedNetworkId then
        self:connectSaved({ networkId = net.savedNetworkId, ssid = net.ssid }, touchmenu_instance)
    elseif not JOINABLE[net.security] then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 uses %2 security, which Nook Wi-Fi does not support. Use Android Wi-Fi settings to join it."),
                net.ssid, SECURITY_NAMES[net.security] or net.security),
        })
    elseif net.security == "open" then
        self:join(net, nil, touchmenu_instance)
    else
        self:askPassword(net, touchmenu_instance)
    end
end

-- KOReader's on-screen keyboard logs every typed character at debug level
-- ("add char"). Turn debug logging down while a password is being typed.
-- Returns a function that restores it; calling that more than once is harmless.
local function suppressDebugLogging()
    local Dbg = require("dbg")
    if not Dbg.is_on then return function() end end
    logger:setLevel(logger.levels.info)
    local restored = false
    return function()
        if restored then return end
        restored = true
        if Dbg.is_on then logger:setLevel(logger.levels.dbg) end
    end
end

-- Returns a message if the password cannot be a WPA/WPA2 passphrase, else nil.
-- The helper checks the same rules.
local function passwordProblem(password)
    if #password == 64 and password:match("^%x+$") then return nil end
    if #password < 8 or #password > 63 then
        return _("Wi-Fi passwords must be 8 to 63 characters.")
    end
    if password:find("[^\32-\126]") then
        return _("Wi-Fi passwords can only use plain (ASCII) letters, digits, and symbols.")
    end
    return nil
end

function NookWifi:askPassword(net, touchmenu_instance)
    local restore_logging = suppressDebugLogging()
    local dialog
    dialog = InputDialog:new{
        title = T(_("Password for %1"), net.ssid),
        text_type = "password",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Connect"),
                is_enter_default = true,
                callback = function()
                    local password = dialog:getInputText()
                    local problem = passwordProblem(password)
                    if problem then
                        UIManager:show(InfoMessage:new{ text = problem })
                        return
                    end
                    UIManager:close(dialog)
                    self:join(net, password, touchmenu_instance)
                end,
            },
        }},
    }
    -- Runs on every way the dialog can close.
    dialog.onCloseWidget = function(this)
        restore_logging()
        return InputDialog.onCloseWidget(this)
    end
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Saves and connects to a new network. If the connection fails, it forgets the
-- network it just created so a mistyped password is not left behind (verified
-- on the Nook). If that removal is ever refused, it says where to remove it.
function NookWifi:join(net, password, touchmenu_instance)
    if self.busy then return end
    local finish = self:beginOperation(T(_("Connecting to %1…"), net.ssid), touchmenu_instance)
    self:ensureEnabled(finish, function()
        local reply, err = Helper.call("join", nil, { ssid = net.ssid, security = net.security, password = password })
        password = nil -- luacheck: ignore 311
        if reply and reply.error == "already_saved" then
            -- Saved meanwhile (e.g. from Android settings): use it, never overwrite it.
            return self:connectSavedStep(finish, reply.savedNetworkId, net.ssid)
        end
        local function cleanUp(network_id, text)
            local forgot = Helper.call("forget", tostring(network_id))
            if forgot and forgot.ok then return finish(text) end
            finish()
            showRemoveInSettings(net.ssid, text)
        end
        -- createdNetworkId, never networkId: that field is the *current* connection.
        if not reply or not reply.ok then
            if reply and reply.createdNetworkId then return cleanUp(reply.createdNetworkId, errorText(reply, err)) end
            return finish(errorText(reply, err))
        end
        local network_id = reply.createdNetworkId
        self:awaitNetwork(finish, function(text) cleanUp(network_id, text) end, network_id, net.ssid)
    end)
end

return NookWifi
