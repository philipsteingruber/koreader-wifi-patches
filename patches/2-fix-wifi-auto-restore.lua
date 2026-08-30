-- Stop a failed/timed-out Wi-Fi connection attempt from silently disabling
-- the "Restore Wi-Fi connection on resume" feature going forward.
--
-- Upstream bug: github.com/koreader/koreader/issues/15728 (open as of
-- 2026-08-24). NetworkMgr's `wifi_was_on` flag is documented as tracking
-- user *intent* ("does the user want Wi-Fi on"), and is correctly only
-- cleared by an explicit user action in NetworkMgr:disableWifi() (gated on
-- its own `interactive` parameter). But NetworkMgr:_abortWifiConnection()
-- -- called from every failed/timed-out connection attempt, never from a
-- deliberate user turn-off -- unconditionally clears the same flag. Once
-- any attempt fails once (out of range, wrong password, a background
-- restore that simply didn't complete in time), NetworkListener:onResume()
-- silently stops attempting the async restore on every subsequent wake,
-- since its own guard checks this same flag:
--
--   if NetworkMgr.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
--
-- From that point on, Wi-Fi stays off after every sleep/resume even with
-- "Restore Wi-Fi connection on resume" enabled, and the next thing that
-- needs the network (e.g. KOSync's own resume-triggered progress sync)
-- falls back to the fully synchronous, UI-freezing interactive connect
-- flow instead -- see this repo's README for the full investigation.
-- Confirmed live on-device 2026-08-24: this is the actual cause of the
-- wake-from-sleep freeze, not the interactive connect flow itself.
--
-- Checked every call site of _abortWifiConnection() in
-- frontend/ui/network/manager.lua before writing this: none of them
-- represent a deliberate "user turned Wi-Fi off" action -- they're all
-- failure/timeout paths (enableWifi's turnOnWifi failing, the same in
-- turnOnWifiAndWaitForConnection, connectivityCheck's 45s give-up,
-- goOnlineToRun's 30s give-up, including its own user-input-abort case,
-- which breaks its own loop rather than routing through here). The one
-- place that should clear intent -- disableWifi() -- doesn't go through
-- _abortWifiConnection at all, so this patch can't interfere with it.
--
-- Fix: wrap _abortWifiConnection() to snapshot wifi_was_on before calling
-- the original, and restore it afterward. Everything else the original
-- function does (killing any in-flight restore-wifi-async.sh, unscheduling
-- the connectivity check, clearing the stale DHCP lease, tearing down
-- Wi-Fi on seamless-toggle platforms) is left completely untouched --
-- this only neutralizes the two wifi_was_on-clearing lines.

local NetworkMgr = require("ui/network/manager")

local orig_abortWifiConnection = NetworkMgr._abortWifiConnection
NetworkMgr._abortWifiConnection = function(self, ...)
    local was_on = self.wifi_was_on
    orig_abortWifiConnection(self, ...)
    self.wifi_was_on = was_on
    G_reader_settings:saveSetting("wifi_was_on", was_on)
end
