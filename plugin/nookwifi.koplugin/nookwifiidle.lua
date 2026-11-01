--[[--
Turns Wi-Fi off once it has gone unused for a while (Nook Wi-Fi → "Turn Wi-Fi
off when unused").

KOReader on Android leaves Wi-Fi on after sync, OPDS and the like: "Action when
done with Wi-Fi" is used only by News Downloader, and "Disable Wi-Fi connection
when inactive" is hidden because Android's NetworkMgr names no interface. Its
noise margin (12 sent packets per 5 minutes) is also too tight for the Nook,
which sent about 10 per 5 minutes while idle (Android and B&N background
traffic, measured on a GlowLight 4 on 2026-11-01). This counts sent packets the
same way, with a limit sized for the Nook: real use (a download, a sync) sends
hundreds.

The counter is world-readable sysfs. wlan0 exists only while Wi-Fi is on, and
the firmware turns Wi-Fi off while the Nook sleeps, so the counter disappears or
restarts from zero; either starts the count again.

State lives in this module, not in a plugin instance: instances are replaced
when switching between the file browser and a book.

@module nookwifiidle
--]]

local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local Helper = require("nookwifihelper")

local SETTING = "nookwifi_idle_off_minutes"
local TX_PATH = "/sys/class/net/wlan0/statistics/tx_packets"
local CHECK_INTERVAL_S = 60
-- Sent packets per minute still counted as unused: about three times the idle
-- rate measured on the Nook (about 2 per minute).
local IDLE_PACKETS_PER_MIN = 6
local OFF_POLL_INTERVAL_S = 0.5
local OFF_TIMEOUT_S = 10

local Idle = {
    -- Offered in the menu; 0 is "never" (the default).
    CHOICES = { 0, 5, 10, 20, 30, 60 },
    scheduled = false,
    samples = {},
}

-- The wlan0 sent-packet counter, or nil while Wi-Fi is off (no interface).
function Idle.readTx()
    local file = io.open(TX_PATH, "rb")
    if not file then return nil end
    local tx = file:read("*number")
    file:close()
    return tx
end

function Idle.minutes()
    local m = G_reader_settings:readSetting(SETTING)
    return type(m) == "number" and m > 0 and m or 0
end

-- Starts the count again: after network activity KOReader tells us about, a
-- wake-up, or a Wi-Fi operation of this plugin.
function Idle.reset()
    Idle.samples = {}
end

-- Turns Wi-Fi off in the background and tells KOReader once it really is off.
-- Never opens Android settings: nobody asked for anything, so a failure is only
-- logged.
local function turnOff()
    local reply, err = Helper.call("setEnabled", "false")
    if not reply or not reply.ok then
        logger.warn("NookWifi: idle turn-off failed:", reply and reply.error or err)
        return
    end
    logger.info("NookWifi: Wi-Fi unused for", Idle.minutes(), "minutes, turning it off")
    UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
    local started = time.now()
    local function poll()
        local state = Helper.call("getState")
        if state and state.ok and state.wifiState == "disabled" then
            NetworkMgr:queryNetworkState()
            UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
        elseif state and state.ok and time.to_s(time.since(started)) < OFF_TIMEOUT_S then
            UIManager:scheduleIn(OFF_POLL_INTERVAL_S, poll)
        else
            logger.warn("NookWifi: Wi-Fi did not report disabled after the idle turn-off")
            NetworkMgr:queryNetworkState()
        end
    end
    UIManager:scheduleIn(OFF_POLL_INTERVAL_S, poll)
end

function Idle.check()
    Idle.scheduled = false
    local minutes = Idle.minutes()
    if minutes == 0 then
        Idle.reset()
        return
    end
    Idle.scheduled = true
    UIManager:scheduleIn(CHECK_INTERVAL_S, Idle.check)

    local tx = Idle.readTx()
    local samples = Idle.samples
    local last = samples[#samples]
    if not tx or (last and tx < last.tx) then
        -- Wi-Fi is off, or came back with a fresh counter.
        Idle.reset()
        if not tx then return end
        samples = Idle.samples
    end
    -- KOReader is connecting: not a moment to turn Wi-Fi off.
    if NetworkMgr.pending_connectivity_check then
        Idle.reset()
        return
    end
    table.insert(samples, { t = time.now(), tx = tx })

    local window_s = minutes * 60
    -- Keep the newest sample that is at least window_s old as the baseline.
    while samples[2] and time.to_s(time.since(samples[2].t)) >= window_s do
        table.remove(samples, 1)
    end
    local first = samples[1]
    if time.to_s(time.since(first.t)) < window_s then return end
    if tx - first.tx <= IDLE_PACKETS_PER_MIN * minutes then
        Idle.reset()
        turnOff()
    end
end

-- Starts the checks if the setting is on and they are not already running.
function Idle.start()
    if Idle.scheduled or Idle.minutes() == 0 then return end
    Idle.reset()
    Idle.scheduled = true
    UIManager:scheduleIn(CHECK_INTERVAL_S, Idle.check)
end

function Idle.stop()
    UIManager:unschedule(Idle.check)
    Idle.scheduled = false
    Idle.reset()
end

function Idle.setMinutes(minutes)
    if minutes > 0 then
        G_reader_settings:saveSetting(SETTING, minutes)
    else
        G_reader_settings:delSetting(SETTING)
    end
    Idle.stop()
    Idle.start()
end

return Idle
