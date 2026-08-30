-- Prevents a plugin's suspend-time network push (CWASync/KOSync's
-- _onSuspend, which calls updateProgress(true, false, true) -- forced
-- networking, no gate) from starting a fresh, blocking interactive Wi-Fi
-- connection while the device is in the middle of going to sleep.
--
-- Root cause, confirmed live via a stack traceback on 2026-08-26:
--
--   Suspend -> Device:_beforeSuspend -> broadcastEvent -> CWASync:handleEvent
--     -> CWASync:updateProgress -> NetworkMgr:willRerunWhenOnline
--     -> NetworkMgr:beforeWifiAction  (fires even with wifi_was_on=true,
--                                      auto_restore_wifi=true -- this path
--                                      never checks those flags at all)
--
-- CWASync's _onResume() correctly defers to the silent restore by checking
-- wifi_was_on/auto_restore_wifi first. Its _onSuspend() has no equivalent
-- check -- it always demands a live connection to push final progress
-- before sleeping, which is exactly backwards: starting a brand-new,
-- potentially 30-40s blocking connection attempt is the worst possible
-- thing to do while the device is trying to suspend.
--
-- Two patching approaches were tried and rejected before this one:
-- 1. Patch CWASync's _onSuspend directly, mirroring its own _onResume gate.
--    Rejected: two separate live attempts to hook this plugin's methods
--    both failed silently on plugin-instantiation/class-table structure --
--    wrapping at the plugin's class table and wrapping the live instance
--    were both tried, and neither wrapper was ever invoked. No proven way
--    to reliably attach to this plugin's internals on this device/build.
-- 2. This one: patch NetworkMgr/Device directly instead. Both are plain
--    require()-able singletons, not per-instance dofile()'d plugins --
--    the same reliable pattern 2-fix-wifi-auto-restore.lua already uses.
--    Also more general: this protects against KOSync (currently dormant,
--    but has the identical unconditional ensure_networking=true) or any
--    future plugin making the same mistake, not just CWASync.
--
-- Device:_beforeSuspend()/_afterResume() are the exact bracket around the
-- whole suspend/resume sequence (confirmed by reading the real source --
-- no existing "is suspending" flag exists to read, so this sets its own).
-- The flag is set true at the very start of _beforeSuspend (before it
-- broadcasts the Suspend event that triggers the problematic call chain
-- above) and cleared at the very start of _afterResume (before the Resume
-- broadcast), so legitimate resume-time interactive connects are
-- completely unaffected -- this only guards the narrow suspend-transition
-- window itself.
--
-- ============================ READ THIS FIRST ============================
-- This patch is a blunt instrument by design. Two consequences you should
-- accept before installing it:
--
-- 1. IT SILENTLY DROPS THE CALLBACK. When the guard is active,
--    beforeWifiAction() returns without invoking the callback it was given.
--    Any plugin's suspend-time network action is discarded, not deferred or
--    queued. On this device that is exactly the point (it stops CWASync's
--    forced pre-sleep progress push). On yours it may mean a sync plugin
--    you rely on quietly skips its final push before sleep, with only a
--    log line to say so. Nothing is lost permanently -- the push happens on
--    the next ordinary sync -- but the pre-sleep one does not happen.
--
-- 2. THE GUARD CAN STICK. If _afterResume never fires (an aborted suspend,
--    a crash during the suspend transition), _wifi_suspend_guard_active
--    stays true and EVERY interactive Wi-Fi connect is blocked until
--    KOReader restarts. Bounded by process lifetime, never persisted to
--    disk -- but if Wi-Fi mysteriously refuses to turn on, restart KOReader
--    and check the log for the message below before blaming anything else.
--
-- The cleaner fix is to gate the offending plugin's own _onSuspend the way
-- its _onResume is already gated. That was not possible here (see approach 1
-- above), and this NetworkMgr-level guard also covers any other plugin with
-- the same bug -- but if you can patch your plugin directly, prefer that.
-- =========================================================================

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")

Device._wifi_suspend_guard_active = false

local orig_beforeSuspend = Device._beforeSuspend
Device._beforeSuspend = function(self, ...)
    self._wifi_suspend_guard_active = true
    return orig_beforeSuspend(self, ...)
end

local orig_afterResume = Device._afterResume
Device._afterResume = function(self, ...)
    self._wifi_suspend_guard_active = false
    return orig_afterResume(self, ...)
end

local orig_beforeWifiAction = NetworkMgr.beforeWifiAction
NetworkMgr.beforeWifiAction = function(self, callback)
    if Device._wifi_suspend_guard_active then
        logger.info("[wifi-suspend-guard] Skipped beforeWifiAction -- device is suspending, won't start a fresh interactive Wi-Fi connection just to push progress before sleep")
        return
    end
    return orig_beforeWifiAction(self, callback)
end
