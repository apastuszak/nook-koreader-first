--[[--
Wi-Fi controls for the Nook GlowLight 4 Plus, backed by the Nook Wi-Fi Helper app.

@module koplugin.NookWifi
--]]

local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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
-- Menu text and checkbox funcs run together on each redraw; reuse one reply.
local STATE_CACHE_S = 1

local GRANT_COMMAND = "adb shell pm grant dev.nookwifi.helper android.permission.ACCESS_COARSE_LOCATION"

local CONNECTING = {
    connecting = true,
    authenticating = true,
    obtaining_ipaddr = true,
    verifying_poor_link = true,
    captive_portal_check = true,
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
        table.insert(lines, T(_("The helper needs location permission to show network names. Grant it once over USB with:\n%1"),
            GRANT_COMMAND))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function NookWifi:showHelperInfo()
    local reply, err = Helper.call("ping")
    local text
    if not reply or not reply.ok then
        text = errorText(reply, err)
    else
        text = T(_("Nook Wi-Fi Helper %1 is installed and responding."), reply.versionName)
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- Saved networks, current first, then strongest signal, then by name.
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
        if reply.scanAvailable then
            label = net.signalLevel and T(_("%1 · signal %2/4"), label, net.signalLevel)
                or T(_("%1 · not in range"), label)
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

-- Starts a Wi-Fi operation: marks the plugin busy and shows progress_text.
-- Returns finish(text, event_name), which ends the operation, shows text, and
-- broadcasts event_name (if any) so KOReader and other plugins (e.g. sync)
-- see the change just as if NetworkMgr had made it.
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
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end
end

-- Calls step(state) every POLL_INTERVAL_S until it returns true. After
-- timeout_s it calls on_timeout(last_state); a helper failure ends the
-- operation through finish.
function NookWifi:pollState(timeout_s, finish, step, on_timeout)
    local started = time.now()
    local function tick()
        local state, msg = self:getState(true)
        if not state then return finish(msg) end
        if step(state) then return end
        if time.to_s(time.since(started)) >= timeout_s then return on_timeout(state) end
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

function NookWifi:connectSaved(net, touchmenu_instance)
    if self.busy then return end
    local name = net.ssid or _("(hidden network)")
    local finish = self:beginOperation(T(_("Connecting to %1…"), name), touchmenu_instance)
    self:ensureEnabled(finish, function()
        local reply, err = Helper.call("connectSaved", tostring(net.networkId))
        if not reply or not reply.ok then return finish(errorText(reply, err)) end
        -- If the network is unreachable, Android drops the current connection and
        -- falls back to another saved network within seconds (seen on the Nook).
        -- Report that as soon as it happens instead of waiting out the timeout.
        local dropped = false
        self:pollState(CONNECT_TIMEOUT_S, finish, function(s)
            if s.connection ~= "connected" then
                dropped = true
                return false
            end
            if s.networkId == net.networkId then
                finish(T(_("Connected to %1."), name), "NetworkConnected")
                return true
            end
            if dropped then
                finish(T(_("Could not connect to %1. %2 instead."), name, connectedText(s)), "NetworkConnected")
                return true
            end
            return false
        end, function(s)
            local text = T(_("Could not connect to %1. It may be out of range."), name)
            if s.connection == "connected" then
                text = text .. " " .. T(_("%1."), connectedText(s))
            end
            finish(text)
        end)
    end)
end

return NookWifi
