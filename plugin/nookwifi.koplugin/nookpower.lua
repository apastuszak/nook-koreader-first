--[[--
The Nook's power-off timer, through the Nook Wi-Fi Helper's powerOff* methods
(see helper/.../PowerOps.java). Mixed into NookWifi by main.lua.

The firmware powers the Nook off after it has slept this long (the hidden
system setting power_off_timeout, in milliseconds; 0 is never). Verified on
the Nook: 2 minutes shut it down about 2 minutes after sleeping, even on USB
power. Changing it needs "Modify system settings" for the helper, which the
user allows on Android's own screen.

@module nookpower
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Helper = require("nookwifihelper")

local HOUR_MS = 60 * 60 * 1000
local DAY_MS = 24 * HOUR_MS

-- The menu asks for the timeout once per item; one helper call serves a redraw.
local CACHE_S = 1

-- The helper accepts only these (PowerRules.ALLOWED_MS).
local CHOICES = { 0, HOUR_MS, 6 * HOUR_MS, DAY_MS, 3 * DAY_MS, 7 * DAY_MS }

local function timeoutText(ms)
    if ms == 0 then
        return _("Never")
    elseif ms < 0 then
        -- Not something the helper writes; shown as stored.
        return T(_("%1 ms"), ms)
    elseif ms < 60000 then
        local seconds = math.floor(ms / 1000 + 0.5)
        return T(N_("1 second", "%1 seconds", seconds), seconds)
    elseif ms % DAY_MS == 0 then
        local days = ms / DAY_MS
        return days == 7 and _("1 week") or T(N_("1 day", "%1 days", days), days)
    elseif ms % HOUR_MS == 0 then
        local hours = ms / HOUR_MS
        return T(N_("1 hour", "%1 hours", hours), hours)
    end
    -- Set some other way, e.g. over ADB.
    local minutes = math.floor(ms / 60000 + 0.5)
    return T(N_("1 minute", "%1 minutes", minutes), minutes)
end

return function(NookWifi, errorText)

local function powerErrorText(reply, err)
    local code = reply and reply.error
    if code == "not_supported" then
        return _("This device does not let the helper change the power-off timer.")
    elseif code == "request_rejected" then
        return _("Android rejected the change.")
    elseif code == "settings_unavailable" then
        return _("Android's system settings screen is not available on this device.")
    end
    return errorText(reply, err)
end

local function call(method, arg)
    local reply, err = Helper.call(method, arg)
    if not reply or not reply.ok then return nil, powerErrorText(reply, err), reply end
    return reply
end

-- A reply's timeoutMs, or nil if it is missing or not a number.
local function replyTimeout(reply)
    return reply and type(reply.timeoutMs) == "number" and reply.timeoutMs or nil
end

-- The current timeout in milliseconds, or nil and a message.
function NookWifi:powerOffTimeout()
    if self.power_cached_at and time.to_s(time.since(self.power_cached_at)) < CACHE_S then
        return self.power_cached
    end
    local reply, msg = call("powerOffGet")
    self.power_cached, self.power_cached_at = replyTimeout(reply), time.now()
    if not reply then return nil, msg end
    if not self.power_cached then return nil, errorText(reply, "bad_reply") end
    return self.power_cached
end

function NookWifi:showWriteSettingsPrompt()
    UIManager:show(ConfirmBox:new{
        text = _("To change this, allow Nook Wi-Fi Helper to modify system settings.\n\n" ..
            "On the next screen, turn on the switch, then come back and choose again."),
        ok_text = _("Open"),
        ok_callback = function()
            local reply, msg = call("powerOffOpenSettings")
            if not reply then UIManager:show(InfoMessage:new{ text = msg }) end
        end,
    })
end

function NookWifi:setPowerOffTimeout(ms, touchmenu_instance)
    local reply, msg, raw = call("powerOffSet", tostring(ms))
    self.power_cached_at = nil
    if not reply then
        if raw and raw.error == "write_settings_needed" then
            self:showWriteSettingsPrompt()
        else
            UIManager:show(InfoMessage:new{ text = msg })
        end
        return
    end
    -- Report what Android read back, not what was asked for.
    local now = replyTimeout(reply)
    if not now then
        UIManager:show(InfoMessage:new{ text = T(_("Could not reach Nook Wi-Fi Helper (%1)."), "bad_reply") })
        return
    end
    UIManager:show(InfoMessage:new{
        text = now == 0 and _("The Nook will not power off by itself.")
            or T(_("The Nook will power off after sleeping for %1."), timeoutText(now)),
        timeout = 3,
    })
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function NookWifi:addPowerMenu(menu_items)
    menu_items.nookpower = {
        text_func = function()
            local ms = self:powerOffTimeout()
            if not ms then return _("Power off after sleeping") end
            return T(_("Power off after sleeping: %1"), timeoutText(ms))
        end,
        sorting_hint = "device",
        enabled_func = function() return self:powerOffTimeout() ~= nil end,
        sub_item_table_func = function()
            local current = self:powerOffTimeout()
            local items = {}
            for __, ms in ipairs(CHOICES) do
                table.insert(items, {
                    text = timeoutText(ms),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function() return self:powerOffTimeout() == ms end,
                    callback = function(touchmenu_instance)
                        self:setPowerOffTimeout(ms, touchmenu_instance)
                    end,
                })
            end
            if current and current ~= 0 then
                local listed = false
                for __, ms in ipairs(CHOICES) do listed = listed or ms == current end
                if not listed then
                    -- A value set some other way: show it, so the list is not left unchecked.
                    table.insert(items, {
                        text = T(_("Custom: %1"), timeoutText(current)),
                        radio = true,
                        checked_func = function() return self:powerOffTimeout() == current end,
                        enabled_func = function() return false end,
                    })
                end
            end
            items[#items].separator = true
            table.insert(items, {
                text = _("About this setting"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("The Nook powers off once it has been asleep this long, which saves battery " ..
                            "when it is not used for a while. Turning it on again takes a long press of the " ..
                            "power button and a full start-up."),
                    })
                end,
            })
            return items
        end,
    }
end

end
