# KOReader Wi-Fi suspend/resume patches

Five [user patches](https://github.com/koreader/koreader/wiki/User-patches) for KOReader,
addressing **four separate bugs** in Wi-Fi handling around sleep and wake, plus one small
UI addition.

These are not one fix with scope creep. Each bug has a distinct root cause, was diagnosed
separately, and is fixed by a separate file. They are grouped here only because they all
live in the same corner of the codebase and compound each other in practice.

## Status and honesty about scope

Everything here was found, fixed and confirmed on **one Kobo running KOReader v2026.07.2**,
over about a week of ordinary daily use. Every fix has been confirmed by a real
reproduction — not by reasoning alone — but "confirmed" means *on that device*. None of it
has been tested across hardware, firmware versions, or non-Kobo platforms.

The strength of that confirmation differs per bug, and each one below says how it was
actually verified. Two were confirmed by an obvious visual symptom disappearing. Two were
confirmed only from logs, because a working fix there looks identical to normal operation.

**Read "What these patches don't fix" below before deciding whether this solves your
problem.** Several real Wi-Fi annoyances in this area are untouched by all five patches, and
one of them will still stall your device for ~30s even with everything installed.

Source-level claims in the patch comments were verified against KOReader's actual source at
both `v2026.07.2` and `master`. Where a claim rests on a call site or a specific function's
behaviour, the comment says so and you can check it.

## The bugs

### 1. A single failed connection permanently disables auto-restore

*Fixed by `patches/2-fix-wifi-auto-restore.lua`. Upstream:
[koreader/koreader#15728](https://github.com/koreader/koreader/issues/15728) — open, unfixed.*

**Credit where it's due: this bug was reported upstream by
[@iav](https://github.com/iav) in July 2026, before the work in
this repo began.** It was hit independently here, and that existing issue's analysis matched
what the device showed. The diagnosis below is a confirmation of their report, not a
discovery. Bugs 2, 3 and 4 were found here and are not filed upstream.

`NetworkMgr.wifi_was_on` is documented as tracking user *intent*. KOReader's own source says
so, at `NetworkMgr:getRestoreMenuTable`:

> `-- i.e., *everything* flips wifi_was_on true, but only direct user interaction (i.e., Menu & Gestures) will flip it off.`

But `NetworkMgr:_abortWifiConnection()` clears that flag unconditionally, and it is called
from every failed or timed-out connection attempt — never from a deliberate turn-off. So one
transient failure (out of range, wrong password, a background restore that just ran long)
silently disables "Restore Wi-Fi connection on resume" from then on, because
`NetworkListener:onResume()` gates on that same flag.

The symptom is not an error. Wi-Fi simply stops coming back after sleep, and the next thing
needing the network falls back to the blocking interactive connect that freezes the UI.

*How it was confirmed:* live in-process logging of the flag across repeated connection
failures. Since the patch went in, `wifi_was_on` has stayed `true` through routine failures
and the original symptom has not recurred. Note that reading the flag from `settings.reader.lua`
on disk is **not** a valid check — that file only reflects the last flush and lags the live
value, which produced several misleading results during the investigation.

### 2. A plugin's pre-sleep sync starts a blocking connection *during* suspend

*Fixed by `patches/experimental/2-fix-wifi-suspend-network-push.lua`.*

Sync plugins (CWASync, KOSync) push final reading progress from `_onSuspend` with networking
forced on and no gate — unlike their own `_onResume`, which correctly checks the restore
flags first. Confirmed by stack traceback:

```text
Device:_beforeSuspend -> broadcastEvent -> CWASync:handleEvent
  -> CWASync:updateProgress -> NetworkMgr:willRerunWhenOnline
  -> NetworkMgr:beforeWifiAction
```

If Wi-Fi is not already up when the device starts suspending, this begins a fresh, blocking,
potentially 30–40s connection attempt *inside the suspend transition* — the worst possible
moment for it.

*How it was confirmed:* **log evidence only.** A working fix here is indistinguishable from
normal operation — there is no visible symptom to watch disappear. The guard's own skip
message was observed firing cleanly, with the device then suspending and resuming normally.
Reproducing the trigger deliberately took several attempts, because the sync plugin's own
~25s "already pushed recently" debounce absorbs most manufactured tests.

### 3. The async restore ignores the concurrency guard that exists for it

*Fixed by `patches/2-fix-wifi-restore-async-race.lua`.*

`NetworkMgr:requestToTurnOnWifi()` already guards against concurrent connection attempts via
`self.pending_connection`, returning `EBUSY` rather than touching `wpa_supplicant` twice. But
`restoreWifiAsync()` — the backgrounded restore-on-resume — never sets that flag, making it
invisible to the guard. An independent interactive attempt arriving mid-restore sails past
the check and fights the async restore over the same `wpa_supplicant` state.

Observed once as a hard freeze requiring a hard reboot; the device never recovered on its own.

*How it was confirmed:* the race was reproduced with the fix in place. The second attempt
correctly hit `EBUSY` and backed off (`A previous connection attempt is still ongoing!` in the
log), with no `wpa_supplicant` collision and no hard reboot.

**Important — this does not make the stall go away.** The fix prevents the *destructive*
collision, and that is all it was ever meant to do. In that same confirmed reproduction a
~30s stall still followed, caused by the sync plugin's own blocking `goOnlineToRun` wait,
which is a separate problem nothing here addresses. The device recovered on its own rather
than needing a reboot. If your complaint is "my Kobo freezes for half a minute after waking",
this patch changes that from *sometimes fatal* to *reliably survivable* — not to *gone*.

### 4. The silent restore only ever tries one saved network

*Fixed by `patches/experimental/2-fix-wifi-restore-single-network.lua`.*

Kobo's network picker disables every *other* saved network in `wpa_supplicant.conf`, leaving
only the one you chose. The async restore starts a fresh `wpa_supplicant` that reads that
same file — so it only ever has that one network to try. Move between two known networks
(home and work, say) and the restore fails after up to 45s, at which point `NetworkMgr` turns
the radio off entirely and leaves you silently offline until you notice.

*How it was confirmed:* a real commute. The device woke at a second location, the widen fired,
it associated with the other network in 4.5s, and the config file was verified restored to its
original single-network state afterwards — checked directly on disk, not just trusted from the
log.

*Known cosmetic nuance:* the **running** `wpa_supplicant` process keeps reporting all networks
as enabled until its next full restart, even though the file on disk is already correct. This
is the live process's own memory lagging, resolves itself within one sleep cycle, and has no
observed effect.

### Plus: a way to see the invisible flag

`patches/2-wifi-intent-menu-toggle.lua` adds a menu entry showing, and letting you flip,
`wifi_was_on` — the flag bug 1 is about. There was previously no way to see it from the UI at
all. Useful for diagnosing this class of problem whether or not you install the fixes.

## What these patches don't fix

This is the section to read if you arrived here from a search for "Kobo freezes after sleep".
The four fixes above remove four specific failure modes. They leave the following intact, and
all of these were observed on the same device *after* every patch was installed.

### The ~30s post-wake stall is still there

The single most likely reason to be disappointed by this repo. Sync plugins call
`NetworkMgr:goOnlineToRun`, which polls synchronously and blocks the UI for up to 30s while
the network comes up. Bug 3's fix stops that from colliding destructively with the async
restore — it does not make the wait asynchronous. Measured user-facing stall after the fix
was still roughly 30–40s in the worst case, which is the same order of magnitude KOReader's
connect paths allow for by design.

Fixing this properly means making that polling loop non-blocking, which is a real upstream
change, not a user patch.

### The silent restore never retries or tells you it failed

If the restore-on-resume attempt fails, KOReader gives up after 45s, turns the radio off, and
says nothing. There is no automatic retry and no notification — you are simply offline until
you happen to notice and reconnect by hand.

Patch 4 makes this *much* rarer by letting the restore try all your saved networks instead of
one, which removes the most common cause. It does not add a retry or a prompt. This is a gap
in KOReader's own design and is untouched here.

### A possible unbounded DNS lookup, observed once and never reproduced

`NetworkMgr:canResolveHostnames()` sits at the very top of `goOnlineToRun` and performs a DNS
lookup with no timeout. A ~20s freeze consistent with this was seen once, shortly after a
fresh Wi-Fi association, on a device whose DNS is managed by a VPN client that may need a
moment to re-settle after reconnecting.

Stated deliberately as a weak observation: **seen once, never reproduced, root cause not
established.** It is not fixed by anything here and may not even be a real bug. It is
mentioned only so that a ~20s stall which none of the four fixes explain doesn't look like
one of them failing.

### Anything that isn't a Kobo

Bugs 3 and 4 concern `restoreWifiAsync()` and Kobo's `restore-wifi-async.sh` / wpa_supplicant
layout specifically. Bugs 1 and 2 are platform-neutral in principle, but nothing here has been
run on a Kindle, PocketBook, Android or desktop build.

### The underlying upstream bugs

These are shims. They wrap functions at runtime and leave KOReader's source untouched, so
every bug above still exists upstream — [#15728](https://github.com/koreader/koreader/issues/15728)
is still open. Installing these fixes your device, not the problem.

## Risk tiers — read before installing

`patches/` holds patches that only change control flow inside KOReader. Worst case they fail
to help.

`patches/experimental/` holds two patches with consequences worth understanding first. **Each
file's own header documents its failure modes in detail — read them.** In summary:

| Patch | What could go wrong |
| --- | --- |
| `2-fix-wifi-suspend-network-push.lua` | Silently drops a plugin's pre-sleep network callback rather than deferring it, so a sync plugin's final pre-sleep push is skipped. Its guard flag can also stick if a suspend is aborted, blocking interactive Wi-Fi until KOReader restarts. |
| `2-fix-wifi-restore-single-network.lua` | **Rewrites `wpa_supplicant.conf`, the file holding your saved Wi-Fi passwords.** Atomic writes and an exact-bytes restore, but validated on one device and one config layout. The revert is not guaranteed in every abort path. |

Back up `wpa_supplicant.conf` before installing the second one if losing saved networks would
be more than an annoyance.

## Installing

Patches go in KOReader's patch directory — on Kobo, `koreader/patches/` on the device.

**Copy the files, not the directory structure.** KOReader's loader (`frontend/userpatch.lua`)
reads its patch directory with a plain `lfs.dir()` scan filtered to `mode == "file"`. It does
**not** recurse. A `patches/experimental/` subfolder on the device would be silently ignored.
The two-tier split in this repo exists to mark risk, not to be reproduced on the device.

So a full install is all five files flat:

```text
koreader/patches/2-fix-wifi-auto-restore.lua
koreader/patches/2-fix-wifi-restore-async-race.lua
koreader/patches/2-fix-wifi-restore-single-network.lua
koreader/patches/2-fix-wifi-suspend-network-push.lua
koreader/patches/2-wifi-intent-menu-toggle.lua
```

Restart KOReader afterwards. Patches are applied at startup, not hot-loaded.

### Don't rename the files

The `2-` prefix is KOReader's load-priority convention, not a version number — `2` means
"after `UIManager` is ready, on every start". Within a priority, files run in natural
alphanumeric order.

Two of these patches wrap the same function (`NetworkMgr.restoreWifiAsync`), so that ordering
is load-bearing: `...-async-race` must load before `...-single-network`, which the current
names ensure. Renaming either can invert the nesting.

### Picking a subset

The three in `patches/` are independent — install any combination.

The one hard rule: **do not install `2-fix-wifi-restore-single-network.lua` without
`2-fix-wifi-restore-async-race.lua`.** That combination gives you config-file rewriting with
no concurrency guard, which is the collision described in bug 3.

## If something goes wrong

### Checking a patch actually loaded

KOReader logs one line per patch as it applies them:

```text
Applying patch: .../koreader/patches/2-fix-wifi-auto-restore.lua
```

If you don't see a line for a file you installed, it isn't being loaded — check that it sits
directly in the patch directory (not a subfolder), that the name still starts with `2-`, and
that the extension is `.lua`. A patch that loads but then throws is logged as `Patching
failed:` with the error, and KOReader shows an on-screen message.

### Recovering

A broken patch will not prevent KOReader from starting. The loader wraps each one in `pcall`,
logs a failure, and carries on.

To disable **all** user patches, create an empty file named `.patches_disabled` inside the
patch directory:

```text
koreader/patches/.patches_disabled
```

This works over USB or SSH without launching KOReader, which makes it the reliable recovery
path. Deleting the file re-enables patches. KOReader also exposes a toggle for this in its
own interface.

To remove a single patch, delete its `.lua` file and restart.

## Reporting a problem

Cross-device confirmation is the thing this repo most needs and the thing its author cannot
produce — everything here was validated on a single Kobo. Reports from other hardware,
firmware and KOReader versions are genuinely useful, including "installed it, nothing
changed".

A useful report says:

- Device and firmware version
- KOReader version
- Which of the five patches are installed
- What you expected and what happened instead
- The relevant part of `crash.log`, with timestamps around the event

**Never paste the contents of `wpa_supplicant.conf`.** It contains every saved Wi-Fi password
in plain text. If a problem involves patch 4, the useful details are the *number* of saved
networks and whether the file's `disabled=1` lines came back after an attempt — not the file
itself. None of these patches ever log network names or passwords, so an unedited `crash.log`
is safe to share on that count; check it for anything else personal before posting.

## Upstream

Bug 1 is filed as [koreader/koreader#15728](https://github.com/koreader/koreader/issues/15728),
reported by @iav, and remains open with no maintainer response. Bugs 2, 3 and 4 are not filed
upstream as of this writing.

These patches are deliberately shaped as monkey-patch shims — the right form for a user patch,
the wrong form for a core contribution. Anyone wanting to fix these properly upstream should
treat the diagnoses here as the useful part, not the code.

## License

[AGPL-3.0](LICENSE), matching KOReader, since these patches load into and wrap its internals.
