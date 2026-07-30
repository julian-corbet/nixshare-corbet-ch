# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth
writing up properly. Nothing here is guaranteed to work, be maintained, or
survive the next cleanup pass. If something in here turns out to matter,
distill the actual finding into [`../studies/`](../studies/README.md) and
let the experiment stay disposable (or delete it).

This is also the open-questions ledger for nixshare's own judgment calls —
every entry below corresponds to a default or design choice that's
reasoned, not measured. Results feed back into `modules/core.nix`'s
defaults as they close.

All open; nothing has been run yet (fresh scaffold, no real hosts has run
this code).

## 001 — is 30s the right default `automountTimeoutSec`?

**Question:** `nixshare.shares.<name>.automountTimeoutSec`
defaults to 30 (twice `establishTimeoutSec`'s own default of 15). Is that
the right margin between "systemd's own per-attempt `TimeoutSec=` gives up"
and "the watchdog concludes the attempt is actually stuck and force-unmounts
it," or too tight/too loose?

**Hypothesis:** 2x is a reasonable starting multiple — enough headroom that
a share which merely takes slightly longer than `establishTimeoutSec` to
fail cleanly on its own (ordinary refused-connection case) isn't also
caught by the watchdog, while still bounding total user-visible hang time
to a low tens-of-seconds range rather than however long a genuinely stuck
kernel RPC call would otherwise sit. Not validated against a real stuck
mount — no host runs nixshare yet.

**Method sketch:** on the actual motivating incident's peer (an overlay
address that's gone fully dark, packets black-holed rather than
RST/ICMP-rejected), instrument how long a `soft,timeo=50,retrans=3` NFSv4.2
mount attempt's *initial TCP connect* phase alone takes before `soft`'s own
retry/give-up logic even gets to apply — TCP connect timeouts on a
black-holed destination are OS/kernel-default-driven (commonly tens of
seconds to minutes) and largely independent of the NFS-level `soft`/`timeo`
tuning, which only bounds RPC-level retries *after* a connection exists.

**Status:** open.

## 002 — is a 10s watchdog poll interval the right cadence?

**Question:** `nixshare.watchdog.pollIntervalSec` defaults to 10.
Against a 30s default `automountTimeoutSec`, that means a stuck mount is
detected somewhere in a 20–30s window after crossing threshold, not
immediately at the threshold instant. Tight enough, or should the poll
cadence be derived from `automountTimeoutSec` (e.g. a fraction of it)
rather than a fixed constant that's fine for the default and wrong for
anyone who overrides `automountTimeoutSec` to something much
smaller/larger?

**Hypothesis:** a fixed constant is simpler and the detection-window slop
it introduces (at most one poll interval) is small relative to
`automountTimeoutSec` at the defaults, but this reasoning doesn't hold if
someone sets a very small `automountTimeoutSec` (say 5s) with the default
10s poll interval still active — worth deriving one from the other, or at
minimum asserting `pollIntervalSec <= automountTimeoutSec` for every share.

**Status:** open.

## 003 — `systemd-escape --path --suffix=mount` vs Nix-eval-time unit naming

**Question:** `pkgs/nixshare-watchdog.nix` resolves a share's mountpoint to
its `.mount` unit name at RUNTIME via the real `systemd-escape` binary,
rather than reimplementing systemd's path-escaping algorithm in Nix at
eval time (the way some NixOS modules do via nixpkgs' internal
`nixos/lib/utils.nix`). This was a deliberate choice for portability (that
internal helper isn't guaranteed present under `system-manager`'s smaller
option surface, and isn't passed as a module argument the way real NixOS
evaluation passes it) — has this actually been checked against a real
`system-manager` target, or just reasoned from `flake.nix`'s existing
`system-manager` inputs?

**Hypothesis:** sound in principle (it's the real command, the same one
systemd's own unit generator effectively uses), but unverified against an
actual `system-manager`-applied host — no host runs nixshare yet.

**Status:** open.

## 004 — does `system-manager` actually support `systemd.mounts`/`systemd.automounts`?

**Question:** `modules/providers/{nfs,cifs}.nix` write plain
`systemd.mounts`/`systemd.automounts` entries with no `system-manager`
branching, on the assumption (by analogy with nixnet's own core.nix, which
uses `systemd.services`/`.timers`/`.paths`/`.tmpfiles.rules` unconditionally
across both backends) that `system-manager`'s `systemd.*` option surface
covers these too. Never directly confirmed against a real
`system-manager`-applied host.

**Hypothesis:** likely fine — `system-manager`'s own stated goal is a
faithful subset of NixOS's `systemd`-related options, and mount/automount
units are a fairly core part of that surface — but flagged explicitly
rather than silently assumed, same discipline nixnet's own
`experiments/README.md` #006 documents for its own unverified-against-a-
real-install assumptions.

**Status:** open.

## 005 — is `umount -f -l` ever insufficient, and does the watchdog need a second escalation tier?

**Question:** the watchdog's entire recovery action is one `umount -f -l`
call. Is there a realistic stuck-mount shape where a lazy force-unmount
doesn't actually free the mountpoint for a new access (leaving the next
automount trigger racing against a not-yet-fully-detached prior one), and
if so, does the watchdog need a second tier (e.g. `systemctl kill
--kill-who=all` on the `.mount` unit's tracked PID first, or a bounded
retry of `umount -f -l` itself) rather than a single fire-and-log attempt?

**Hypothesis:** `umount -f -l`'s lazy semantics (detach from the namespace
immediately; kernel-side cleanup happens whenever the underlying reference
count actually drops) should make this a non-issue for the specific
failure shape this project targets (a session-blocking stat()/access()
against the mountpoint), but this is reasoned from `umount(8)`'s documented
behavior, not exercised against a real stuck mount.

**Status:** open.
