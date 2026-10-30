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
                enabled_func = function()
                    return not self.busy and self:getState() ~= nil
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local state = self:getState(true)
                    if state then
                        self:setWifi(not state.enabled, touchmenu_instance)
                    end
                end,
            },
            {
                text = _("Open Android Wi-Fi settings"),
                callback = function() require("android").openWifiSettings() end,
                separator = true,
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

-- Requests the change, then polls until Wi-Fi actually reaches the target state
-- (and, when turning on, until it connects or gives up), so success is only
-- reported once it is real.
function NookWifi:setWifi(on, touchmenu_instance)
    if self.busy then return end
    local reply, err = Helper.call("setEnabled", on and "true" or "false")
    if not reply or not reply.ok then
        UIManager:show(InfoMessage:new{ text = errorText(reply, err) })
        return
    end

    self.busy = true
    local progress = InfoMessage:new{ text = on and _("Turning Wi-Fi on…") or _("Turning Wi-Fi off…") }
    UIManager:show(progress)
    local target = on and "enabled" or "disabled"
    local waiting_for_connection = false
    local started = time.now()

    -- event_name, if set, is broadcast so KOReader and other plugins (e.g. sync)
    -- see the change just as if NetworkMgr had made it.
    local function finish(text, event_name)
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

    UIManager:broadcastEvent(Event:new(on and "NetworkConnecting" or "NetworkDisconnecting"))

    local function poll()
        local state, msg = self:getState(true)
        if not state then return finish(msg) end
        local elapsed = time.to_s(time.since(started))
        if not waiting_for_connection then
            if state.wifiState == target then
                if not on then return finish(_("Wi-Fi is off."), "NetworkDisconnected") end
                waiting_for_connection = true
                started, elapsed = time.now(), 0
            elseif elapsed >= STATE_TIMEOUT_S then
                return finish(T(_("Wi-Fi did not turn %1 within %2 seconds."),
                    on and _("on") or _("off"), STATE_TIMEOUT_S))
            end
        end
        if waiting_for_connection then
            if state.connection == "connected" then
                return finish(T(_("Wi-Fi is on. %1."), connectedText(state)), "NetworkConnected")
            elseif elapsed >= CONNECT_TIMEOUT_S then
                return finish(_("Wi-Fi is on but not connected to a network."))
            end
        end
        UIManager:scheduleIn(POLL_INTERVAL_S, poll)
    end
    UIManager:scheduleIn(POLL_INTERVAL_S, poll)
end

return NookWifi
