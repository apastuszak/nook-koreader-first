--[[--
Opens the stock Nook home screen from KOReader, through the Nook Wi-Fi Helper's
openNookHome method (it starts com.nook.partner's launcher entry, which shows
bn.ereader's home screen; verified on the Nook). Mixed into NookWifi by main.lua.

@module nookhome
--]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Helper = require("nookwifihelper")

return function(NookWifi, errorText)

function NookWifi:openNookHome()
    local reply, err = Helper.call("openNookHome")
    if reply and reply.ok then return end
    local text
    if reply and reply.error == "nook_home_unavailable" then
        text = _("The Nook home screen is not available on this device.")
    else
        text = errorText(reply, err)
    end
    UIManager:show(InfoMessage:new{ text = text })
end

function NookWifi:registerNookHomeActions()
    Dispatcher:registerAction("nookhome_open", {
        category = "none",
        event = "NookHomeOpen",
        title = _("Open Nook home"),
        general = true,
    })
end

-- Gesture or key action.
function NookWifi:onNookHomeOpen()
    self:openNookHome()
    return true
end

function NookWifi:addNookHomeMenu(menu_items)
    menu_items.nookhome = {
        text = _("Open Nook home"),
        sorting_hint = "tools",
        callback = function() self:openNookHome() end,
    }
end

end
