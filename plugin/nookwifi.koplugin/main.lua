--[[--
Wi-Fi controls for the Nook GlowLight 4 Plus, backed by the Nook Wi-Fi Helper app.

@module koplugin.NookWifi
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

if not Device:isAndroid() then
    return { disabled = true }
end

local Helper = require("nookwifihelper")

local NookWifi = WidgetContainer:extend{
    name = "nookwifi",
    is_doc_only = false,
}

function NookWifi:init()
    self.ui.menu:registerToMainMenu(self)
end

function NookWifi:addToMainMenu(menu_items)
    menu_items.nookwifi = {
        text = _("Nook Wi-Fi"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Helper status"),
                keep_menu_open = true,
                callback = function() self:showHelperStatus() end,
            },
        },
    }
end

function NookWifi:showHelperStatus()
    local reply, err = Helper.call("ping")
    local text
    if err == "helper_not_installed" then
        text = _("Nook Wi-Fi Helper is not installed.")
    elseif not reply then
        text = T(_("Could not reach Nook Wi-Fi Helper (%1)."), err)
    elseif not reply.ok then
        text = T(_("Nook Wi-Fi Helper refused the request (%1)."), reply.error)
    elseif reply.protocol ~= Helper.PROTOCOL then
        text = T(_("Nook Wi-Fi Helper %1 uses protocol %2; this plugin expects %3. Update both."),
            reply.versionName, reply.protocol, Helper.PROTOCOL)
    else
        text = T(_("Nook Wi-Fi Helper %1 is installed and responding."), reply.versionName)
    end
    UIManager:show(InfoMessage:new{ text = text })
end

return NookWifi
