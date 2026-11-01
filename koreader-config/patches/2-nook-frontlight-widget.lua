-- Use KOReader's own FrontLightWidget (the Kindle/Kobo-style sliders)
-- instead of the native Android light dialog on Android devices.
-- Requires WRITE_SETTINGS to be granted to org.koreader.launcher on the Nook GL4 Plus:
--   adb shell appops set org.koreader.launcher WRITE_SETTINGS allow
--
-- SPDX-License-Identifier: AGPL-3.0-or-later

local Device = require("device")

if not Device:isAndroid() then
    return
end

local UIManager = require("ui/uimanager")
local logger = require("logger")

function Device:showLightDialog()
    -- Delay to the next tick, like the stock implementation does, so the
    -- event loop can drain the input queue first.
    UIManager:nextTick(function()
        local FrontLightWidget = require("ui/widget/frontlightwidget")
        UIManager:show(FrontLightWidget:new{})
    end)
end

logger.info("nook-frontlight-widget: Device:showLightDialog replaced with FrontLightWidget")
