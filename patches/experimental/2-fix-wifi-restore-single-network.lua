-- Fixes the silent restore-on-resume only ever retrying the ONE Wi-Fi
-- network the Kobo FIRMWARE left "enabled" in wpa_supplicant.conf, instead
-- of falling back to any of your other saved networks.
--
-- CORRECTION (2026-08-30): an earlier version of this comment claimed that
-- KOReader's own Wi-Fi menu is what disables the other saved networks. That
-- is wrong -- KOReader never writes this file at all. Corrected below. The
-- conclusion (the restore only ever has one candidate) is unchanged; only
-- the mechanism was misattributed.
--
-- Background: KOReader never writes wpa_supplicant.conf. It configures
-- networks at RUNTIME only -- ADD_NETWORK / SET_NETWORK / ENABLE_NETWORK via
-- lj-wpaclient, from WpaSupplicant:authenticateNetwork -- and there is no
-- SAVE_CONFIG call anywhere in the KOReader tree, so none of that is ever
-- persisted. DISABLE_NETWORK likewise has zero call sites. The `disabled=1`
-- lines in this file are written by the Kobo firmware (nickel), not by
-- KOReader. (Verified 2026-08-30 by code search against koreader/koreader:
-- the only reference to wpa_supplicant.conf in the whole repo is
-- platform/kobo/enable-wifi.sh READING it.)
--
-- That distinction is the actual bug: the two connect paths draw on
-- different sets of networks. The interactive path injects your chosen
-- network into an ALREADY-RUNNING wpa_supplicant, so it works anywhere. The
-- async silent restore-on-resume (NetworkMgr:restoreWifiAsync(), just
-- `os.execute("./restore-wifi-async.sh")`) reaches enable-wifi.sh, which
-- starts a BRAND-NEW `wpa_supplicant -c /mnt/onboard/.kobo/wpa_supplicant.conf`
-- on every resume -- so its only candidates are whatever the firmware last
-- left enabled in that file, regardless of what KOReader itself knows about.
-- On this device that is exactly one network. If you've moved to a different
-- known network since (home -> work, or back), the restore
-- fails after up to 45s, and NetworkMgr responds by turning the radio off
-- entirely (see `_abortWifiConnection`) -- leaving you fully offline,
-- silently, until you notice and manually reconnect. Confirmed happening
-- on real commutes both directions (2026-08-27 evening, 2026-08-28
-- morning).
--
-- Fix: right before the async restore fires, temporarily re-enable every
-- OTHER saved network in the config file too, so the fresh
-- wpa_supplicant process actually has multiple candidates to scan and
-- pick from on its own -- exactly what it would do if you'd used the
-- interactive picker at each new location. Once the restore attempt
-- concludes (success or give-up), put the file back exactly as it was,
-- so Kobo's own single-enabled-network convention is undisturbed for any
-- future manual reconnect.
--
-- Why a file edit and not a live `wpa_cli enable_network` call: by the
-- time this runs, Wi-Fi is off and there's no wpa_supplicant process
-- running yet to send runtime commands to -- restore-wifi-async.sh's own
-- enable-wifi.sh step is what starts a *fresh* wpa_supplicant, which reads
-- its network list from this file at startup. There's nothing to talk to
-- until after that file has already been read.
--
-- Safety properties, deliberately kept simple:
--   * The original file content is kept in memory (not touched on disk)
--     until the very same attempt concludes -- we never try to compute
--     what the "correct" post-attempt state should be, we just restore the
--     exact original bytes. This means we never need to know or guess
--     which network "should" end up enabled long-term -- that stays
--     entirely the Kobo firmware's business, not ours.
--   * Writes are temp-file-then-atomic-rename (os.rename on the same
--     directory/filesystem), so a crash or interruption mid-write can
--     never leave a half-written config (which holds every saved Wi-Fi
--     password) on disk.
--   * If a widen is already in effect (a saved snapshot exists) when this
--     fires again, it's a no-op -- the gsub below finds nothing left to
--     widen on an already-widened file, so we never overwrite our one
--     saved snapshot with already-modified content.
--   * If any read/write step fails for any reason, this backs off loudly
--     (logs a warning) rather than guessing or forcing anything.
--
-- ============================ READ THIS FIRST ============================
-- This is the highest-risk patch in this set. It REWRITES the file holding
-- every saved Wi-Fi password. It has been validated on exactly one device,
-- one firmware, one config layout. Known limitations, stated plainly:
--
-- 1. DEVICE SCOPE. Path detection assumes Kobo's layout. On anything else
--    resolveConfPath() falls through to /etc/wpa_supplicant/wpa_supplicant.conf,
--    a file this patch has never been tested against. The `\tdisabled=1\n`
--    match also assumes tab indentation; a space-indented config simply
--    no-ops (safe), but has not been exercised.
--
-- 2. IT ALSO FIRES AT STARTUP, not just on resume. restoreWifiAsync() has
--    two call sites (NetworkListener:onResume and NetworkMgr:init), so the
--    widen happens on every KOReader launch where Wi-Fi restore is armed.
--
-- 3. THE REVERT IS NOT GUARANTEED. restoreNetworks() only runs from the
--    connectivityCheck wrapper below, but _abortWifiConnection() calls
--    unscheduleConnectivityCheck(), killing that loop. An abort from outside
--    the loop (e.g. turning Wi-Fi off manually mid-restore) leaves the file
--    widened. It self-heals on the next completed attempt -- the n == 0
--    guard preserves the original snapshot -- but if KOReader exits or
--    crashes first, that in-memory snapshot is lost and the file stays
--    widened permanently. Practical impact is low (all saved networks
--    enabled is arguably better behaviour, and your next manual pick
--    re-narrows it), but it is NOT the advertised "always restored".
--
-- 4. PAIR IT. This wraps the same function as
--    2-fix-wifi-restore-async-race.lua, which loads FIRST (alphanumeric
--    order), making this one the outer wrapper. Do not install this patch
--    without that one -- you would get config rewriting with no concurrency
--    guard. Don't rename either file.
--
-- Back up wpa_supplicant.conf before installing if losing saved networks
-- would be more than a minor annoyance.
-- =========================================================================

local NetworkMgr = require("ui/network/manager")
local logger = require("logger")

-- Confirmed via device inspection (2026-08-28): this Kobo uses the FW 5.x+
-- layout, so /mnt/onboard/.kobo/wpa_supplicant.conf does not exist and
-- enable-wifi.sh falls back to this path. Checked at call time (not
-- cached) in case that ever changes.
local WPA_CONF_FW5 = "/mnt/onboard/.kobo/wpa_supplicant.conf"
local WPA_CONF_DEFAULT = "/etc/wpa_supplicant/wpa_supplicant.conf"

local function resolveConfPath()
    local f = io.open(WPA_CONF_FW5, "r")
    if f then
        f:close()
        return WPA_CONF_FW5
    end
    return WPA_CONF_DEFAULT
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Atomic: write to a sibling temp file, then rename over the target.
-- os.rename is atomic as long as both paths are on the same filesystem,
-- which they are here (same directory).
local function atomicWrite(path, data)
    local tmp = path .. ".tmp-wifiwiden"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(data)
    f:close()
    return os.rename(tmp, path) and true or false
end

-- The original file content, saved only while a widen is in effect. nil
-- means "no widen currently active" -- used as the guard against both
-- double-widening and double-restoring.
local _saved_conf = nil

local function widenNetworks()
    local path = resolveConfPath()
    local data = readFile(path)
    if not data then
        logger.warn("[wifi-widen] Could not read", path, "-- leaving Wi-Fi config untouched")
        return
    end
    -- Every network the Kobo firmware has disabled is marked with a
    -- `disabled=1` line inside its network={} block. Stripping that line
    -- is equivalent to disabled=0 (wpa_supplicant treats a missing
    -- `disabled` key as enabled) and touches nothing else in the file --
    -- no reformatting, no rewriting of ssid/psk lines.
    local widened, n = data:gsub("\tdisabled=1\n", "")
    if n == 0 then
        -- Nothing to widen: either everything's already enabled, or (more
        -- likely) a widen from a still-in-progress attempt is already
        -- active. Either way, don't touch _saved_conf.
        return
    end
    if not atomicWrite(path, widened) then
        logger.warn("[wifi-widen] Failed to write widened Wi-Fi config -- leaving original in place")
        return
    end
    _saved_conf = data
    logger.info("[wifi-widen] Temporarily enabled", n, "additional saved network(s) for this restore attempt")
end

local function restoreNetworks()
    if not _saved_conf then return end
    local path = resolveConfPath()
    if atomicWrite(path, _saved_conf) then
        logger.info("[wifi-widen] Restored original (single-network) Wi-Fi config")
    else
        logger.warn("[wifi-widen] Failed to restore original Wi-Fi config -- it will stay widened until the next successful write")
    end
    _saved_conf = nil
end

local orig_restoreWifiAsync = NetworkMgr.restoreWifiAsync
NetworkMgr.restoreWifiAsync = function(self, ...)
    widenNetworks()
    return orig_restoreWifiAsync(self, ...)
end

-- connectivityCheck is the shared polling loop both the async restore and
-- the interactive connect path eventually run through (see
-- 2-fix-wifi-restore-async-race.lua's own comments on this function). It's
-- called every 250ms via UIManager:scheduleIn(0.25, self.connectivityCheck, ...),
-- and since that's a plain table lookup on `self` (== NetworkMgr) at
-- schedule time, every reschedule automatically picks up this wrapper too.
-- Nothing else in this set wraps connectivityCheck, so this half has no
-- load-order dependency -- but note the restoreWifiAsync wrapper above DOES
-- share a function with 2-fix-wifi-restore-async-race.lua (see item 4 in the
-- header).
local orig_connectivityCheck = NetworkMgr.connectivityCheck
NetworkMgr.connectivityCheck = function(self, iter, callback, widget)
    orig_connectivityCheck(self, iter, callback, widget)
    if not _saved_conf then return end
    if iter >= 180 then
        -- Give-up threshold, matching connectivityCheck's own (the abort
        -- already ran inside orig above).
        restoreNetworks()
    elseif self.is_wifi_on and self.is_connected then
        -- Success, matching connectivityCheck's own success condition (the
        -- success handling already ran inside orig above).
        restoreNetworks()
    end
end
