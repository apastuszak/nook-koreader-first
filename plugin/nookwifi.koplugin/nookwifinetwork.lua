--[[--
Routes KOReader's own Wi-Fi handling through the Nook Wi-Fi Helper.

KOReader's Android device code makes NetworkMgr:turnOnWifi/turnOffWifi open
Android's Wi-Fi settings and treats "Wi-Fi on" as "connected". Replacing those
methods makes the Network menu toggle, the Wi-Fi gestures, and "Action when
Wi-Fi is off: turn on" (used by sync, OPDS, news, etc.) toggle Wi-Fi directly.
Every override falls back to KOReader's original method if the helper cannot
be reached, so a missing helper restores stock behavior.

@module nookwifinetwork
--]]

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local Helper = require("nookwifihelper")

local OFF_POLL_INTERVAL_S = 0.25
local OFF_TIMEOUT_S = 10

local Network = {
    installed = false,
}

local orig = {}

-- Returns the helper's getState reply, or nil if the helper cannot be used.
local function helperState()
    local reply = Helper.call("getState")
    if reply and reply.ok then return reply end
    return nil
end

local function isWifiOn(self)
    local state = helperState()
    if not state then return orig.isWifiOn(self) end
    return state.enabled
end

-- NetworkMgr:enableWifi passes a callback that starts its connectivity check
-- (polling isWifiOn and isConnected, then broadcasting NetworkConnected), so
-- once Android accepts the request there is nothing left to wait for here.
-- Returning false makes enableWifi abort the attempt.
local function turnOnWifi(self, complete_callback, interactive)
    local reply, err = Helper.call("setEnabled", "true")
    if not reply then
        logger.warn("NookWifi: turnOnWifi falling back to stock behavior:", err)
        return orig.turnOnWifi(self, complete_callback, interactive)
    end
    if not reply.ok then
        logger.warn("NookWifi: turnOnWifi rejected:", reply.error)
        return false
    end
    if complete_callback then
        complete_callback()
    end
    return true
end

-- Waits for Wi-Fi to actually report disabled before running the callback,
-- which broadcasts NetworkDisconnected and refreshes menus.
local function turnOffWifi(self, complete_callback)
    local reply, err = Helper.call("setEnabled", "false")
    if not reply then
        logger.warn("NookWifi: turnOffWifi falling back to stock behavior:", err)
        return orig.turnOffWifi(self, complete_callback)
    end
    if not reply.ok then
        logger.warn("NookWifi: turnOffWifi rejected:", reply.error)
    end
    local started = time.now()
    local function poll()
        local state = helperState()
        local done = not state or state.wifiState == "disabled"
        if done or time.to_s(time.since(started)) >= OFF_TIMEOUT_S then
            if not done then
                logger.warn("NookWifi: Wi-Fi did not report disabled within", OFF_TIMEOUT_S, "s")
            end
            if complete_callback then
                complete_callback()
            end
        else
            UIManager:scheduleIn(OFF_POLL_INTERVAL_S, poll)
        end
    end
    poll()
end

-- Used by NetworkListener ("Already connected to network …") and connectivity checks.
local function getCurrentNetwork(self)
    local state = helperState()
    if not state then return orig.getCurrentNetwork(self) end
    if state.connection == "connected" and state.ssid then
        return { ssid = state.ssid }
    end
end

-- On Android the Network menu shows "Wi-Fi settings"; offer KOReader's real toggle instead.
local function getWifiMenuTable(self)
    if helperState() then
        return self:getWifiToggleMenuTable()
    end
    return orig.getWifiMenuTable(self)
end

local function seamlessToggle()
    return true
end

--- Installs the overrides once per KOReader session.
function Network.install()
    if Network.installed then return end
    Network.installed = true

    orig.isWifiOn = NetworkMgr.isWifiOn
    orig.turnOnWifi = NetworkMgr.turnOnWifi
    orig.turnOffWifi = NetworkMgr.turnOffWifi
    orig.getCurrentNetwork = NetworkMgr.getCurrentNetwork
    orig.getWifiMenuTable = NetworkMgr.getWifiMenuTable

    NetworkMgr.isWifiOn = isWifiOn
    NetworkMgr.turnOnWifi = turnOnWifi
    NetworkMgr.turnOffWifi = turnOffWifi
    NetworkMgr.getCurrentNetwork = getCurrentNetwork
    NetworkMgr.getWifiMenuTable = getWifiMenuTable

    -- Android declares Wi-Fi toggling non-seamless because it needs the settings
    -- screen. With the helper it does not, which lets KOReader turn Wi-Fi back
    -- off after a failed connection attempt, as on other e-readers.
    if helperState() then
        Device.hasSeamlessWifiToggle = seamlessToggle
    end

    NetworkMgr:queryNetworkState()
    logger.info("NookWifi: NetworkMgr hooks installed, seamless toggle:", Device:hasSeamlessWifiToggle())
end

return Network
