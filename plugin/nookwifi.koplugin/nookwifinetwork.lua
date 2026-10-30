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
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local Helper = require("nookwifihelper")

local OFF_POLL_INTERVAL_S = 0.25
local OFF_TIMEOUT_S = 10
local ON_POLL_INTERVAL_S = 0.5
local ON_PROGRESS_TIMEOUT_S = 20

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
-- KOReader's toggle closes its "Turning on Wi-Fi…" message as soon as
-- turnOnWifi returns, which elsewhere blocks until Wi-Fi is up. This one returns
-- at once, so for user toggles keep the same message up until Wi-Fi connects,
-- then say which network it joined. NetworkMgr's own connectivity check still
-- does the real work (events, menu refresh) independently.
local function showProgressUntilConnected()
    local progress = InfoMessage:new{ text = _("Turning on Wi-Fi…") }
    UIManager:show(progress)
    local started = time.now()
    local function poll()
        local state = helperState()
        if state and state.connection == "connected" then
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text = state.ssid and T(_("Wi-Fi on. Connected to %1."), state.ssid) or _("Wi-Fi on."),
                timeout = 3,
            })
        elseif not state then
            UIManager:close(progress)
        elseif time.to_s(time.since(started)) >= ON_PROGRESS_TIMEOUT_S then
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{ text = _("Wi-Fi is on but not connected to a network yet."), timeout = 3 })
        else
            UIManager:scheduleIn(ON_POLL_INTERVAL_S, poll)
        end
    end
    UIManager:scheduleIn(ON_POLL_INTERVAL_S, poll)
end

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
    -- Only the menu toggle and Wi-Fi gestures pass interactive; "Action when
    -- Wi-Fi is off" shows its own "Connecting to Wi-Fi…" message instead.
    if interactive then
        showProgressUntilConnected()
    end
    return true
end

-- Fallback once the helper has failed: open Android's Wi-Fi settings so the
-- user can finish, without the callback. Stock turnOffWifi would run the
-- callback right after opening Settings, broadcasting NetworkDisconnected while
-- Wi-Fi may still be on (frontend/device/android/device.lua at b44e9b7).
-- Background calls (NetworkMgr:_abortWifiConnection passes no callback) never
-- open Settings: that would pop up over whatever the user is reading.
local function openSettingsOnly(self, interactive)
    if interactive then
        orig.turnOffWifi(self, nil)
    end
    self:queryNetworkState()
end

-- Waits for Wi-Fi to actually report disabled before running the callback,
-- which broadcasts NetworkDisconnected and refreshes menus. The callback runs
-- only once Wi-Fi is really off, so KOReader is never told it is off while on.
local function turnOffWifi(self, complete_callback)
    local interactive = complete_callback ~= nil
    local reply, err = Helper.call("setEnabled", "false")
    if not reply then
        if err == "helper_not_installed" and interactive then
            -- No helper at all: behave exactly like stock KOReader.
            logger.warn("NookWifi: helper not installed, turnOffWifi uses stock behavior")
            return orig.turnOffWifi(self, complete_callback)
        end
        -- The helper is there but failed (jni_error, bad_reply, protocol_mismatch).
        logger.warn("NookWifi: turnOffWifi failed:", err)
        return openSettingsOnly(self, interactive)
    end
    if not reply.ok then
        logger.warn("NookWifi: turnOffWifi rejected:", reply.error)
        return openSettingsOnly(self, interactive)
    end
    local started = time.now()
    local function poll()
        local state = helperState()
        if not state then
            logger.warn("NookWifi: lost the helper while turning Wi-Fi off")
            return openSettingsOnly(self, interactive)
        end
        if state.wifiState == "disabled" then
            if complete_callback then complete_callback() end
        elseif time.to_s(time.since(started)) >= OFF_TIMEOUT_S then
            -- Still on: refresh NetworkMgr's view instead of announcing a disconnect.
            logger.warn("NookWifi: Wi-Fi did not report disabled within", OFF_TIMEOUT_S, "s")
            self:queryNetworkState()
        else
            UIManager:scheduleIn(OFF_POLL_INTERVAL_S, poll)
        end
    end
    poll()
end

-- getCurrentNetwork is deliberately not overridden. Returning an SSID would arm
-- NetworkMgr:hasLeaseForCurrentNetwork, which compares it with lease_ssid; that
-- is only set by NetworkMgr's own connectivity checks, so connections made at
-- startup, by Android, or by this plugin would look like stale leases and
-- trigger needless reconnects. Stock Android returns nil, meaning "unknown".

-- On Android the Network menu shows "Wi-Fi settings"; offer KOReader's real toggle instead.
local function getWifiMenuTable(self)
    if helperState() then
        return self:getWifiToggleMenuTable()
    end
    return orig.getWifiMenuTable(self)
end

-- Checked live, so that if the helper breaks or is removed mid-session KOReader
-- goes back to treating toggling as non-seamless (and stops turning Wi-Fi off in
-- the background after failed connection attempts).
local function seamlessToggle()
    return helperState() ~= nil
end

--- Installs the overrides once per KOReader session.
function Network.install()
    if Network.installed then return end
    Network.installed = true

    orig.isWifiOn = NetworkMgr.isWifiOn
    orig.turnOnWifi = NetworkMgr.turnOnWifi
    orig.turnOffWifi = NetworkMgr.turnOffWifi
    orig.getWifiMenuTable = NetworkMgr.getWifiMenuTable

    NetworkMgr.isWifiOn = isWifiOn
    NetworkMgr.turnOnWifi = turnOnWifi
    NetworkMgr.turnOffWifi = turnOffWifi
    NetworkMgr.getWifiMenuTable = getWifiMenuTable

    -- Android declares Wi-Fi toggling non-seamless because it needs the settings
    -- screen. With a working helper it does not, which lets KOReader turn Wi-Fi
    -- back off after a failed connection attempt, as on other e-readers.
    Device.hasSeamlessWifiToggle = seamlessToggle

    NetworkMgr:queryNetworkState()
    logger.info("NookWifi: NetworkMgr hooks installed, seamless toggle:", Device:hasSeamlessWifiToggle())
end

return Network
