-- Adds a "Wi-Fi auto-reconnect armed" menu item (Settings/gear -> Network)
-- that shows and lets you manually flip NetworkMgr's internal wifi_was_on
-- flag -- the same flag 2-fix-wifi-auto-restore.lua protects from being
-- silently cleared on a routine connection failure
-- (see koreader/koreader#15728).
--
-- There was previously no way to see or control this from the UI at all --
-- "Restore Wi-Fi connection on resume" (auto_restore_wifi) only controls
-- whether the *feature* is enabled; wifi_was_on is the separate, invisible
-- per-moment state that feature is gated on, and until now the only way to
-- change it was indirectly, by actually connecting or disconnecting.
--
-- Two call sites need patching for a menu item to actually work:
-- 1. NetworkMgr:getMenuTable() -- populates the entry itself.
-- 2. Both menu-order tables (reader + filemanager) -- an entry that
--    exists in getMenuTable()'s output but isn't listed in menu_order
--    simply never renders; confirmed by reading how both menus consume
--    the ordering table.

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local ReaderMenuOrder = require("ui/elements/reader_menu_order")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local _ = require("gettext")

local function insertAfterRestore(order_table)
    if not order_table.network then return end
    for i, key in ipairs(order_table.network) do
        if key == "network_restore" then
            table.insert(order_table.network, i + 1, "network_wifi_intent")
            return
        end
    end
    -- Fallback: "network_restore" wasn't found (shouldn't happen on a
    -- device with hasWifiRestore()) -- append rather than silently drop it.
    table.insert(order_table.network, "network_wifi_intent")
end

insertAfterRestore(ReaderMenuOrder)
insertAfterRestore(FileManagerMenuOrder)

function NetworkMgr:getWifiIntentMenuTable()
    return {
        text_func = function()
            return NetworkMgr.wifi_was_on
                and _("Wi-Fi auto-reconnect is armed")
                or _("Wi-Fi auto-reconnect is disarmed")
        end,
        help_text = _([[This is the internal flag "Restore Wi-Fi connection on resume" actually runs on -- it's what gets checked at the moment you wake the device, separately from whether that setting is turned on.

It gets disarmed by explicitly turning Wi-Fi off yourself, and (before this patch) used to also get disarmed by any failed/timed-out connection attempt -- meaning auto-restore could silently stop working after a single hiccup, with no way to see why or fix it without reconnecting manually.

Toggle this on to force auto-reconnect to try again on the next wake, even after a failure. Toggle it off if you'd rather Wi-Fi stayed off until you turn it on yourself.]]),
        checked_func = function() return NetworkMgr.wifi_was_on == true end,
        enabled_func = function() return Device:hasWifiRestore() end,
        callback = function()
            local new_value = not NetworkMgr.wifi_was_on
            NetworkMgr.wifi_was_on = new_value
            G_reader_settings:saveSetting("wifi_was_on", new_value)
        end,
        keep_menu_open = true,
    }
end

local orig_getMenuTable = NetworkMgr.getMenuTable
NetworkMgr.getMenuTable = function(self, common_settings)
    orig_getMenuTable(self, common_settings)
    if Device:hasWifiRestore() then
        common_settings.network_wifi_intent = self:getWifiIntentMenuTable()
    end
end
