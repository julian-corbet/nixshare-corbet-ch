# nixshare

Declarative NFS/CIFS shares. The client side names its server as a
[nixnet](https://github.com/julian-corbet/nixnet-corbet-ch) peer instead
of a hardcoded address, plus a watchdog that detects a stuck automount
attempt and force-unmounts it **before** it hangs the session, instead of
after. The server side exports a ZFS `sharenfs`/`sharesmb`-carried tree
matrix — kernel NFSv4 + Samba, both fully declarative.

**The problem this solves:** a laptop with several NFS automounts, every
one hardcoded to a single VPN-overlay address for its server. The overlay
dies (VPN daemon crash, management server hiccup, whatever) — every
automount attempt now blocks against a dead address. The first program
that happens to `stat()` one of those mountpoints (a shell's prompt doing
tab-completion, a file manager populating its sidebar, anything) hangs
with it, and because the hang is inside an uninterruptible kernel wait,
not even `kill -9` frees it. The only way out used to be a manual
`sudo umount -f -l` per stuck mount, entered by hand, after the session was
already wedged.

[nixnet](https://github.com/julian-corbet/nixnet-corbet-ch) already solves
the *address* half of this generically — a peer is reachable over several
transports (LAN, overlay, …), nixnet health-checks them and keeps
`/etc/hosts` pointed at whichever one currently works. nixshare is the
NFS/CIFS-specific layer on top of that: share definitions that name their
server as a nixnet peer instead of a literal address (so a share
automatically gets nixnet's LAN/overlay failover, with zero address logic
of nixshare's own), plus the piece nixnet alone doesn't cover — a watchdog
that catches an in-flight mount attempt that's taking too long and
proactively unsticks it, rather than leaving a human to notice the session
is wedged and reach for `sudo umount -f -l` themselves.

## Quickstart

```nix
# flake.nix (consumer side)
{
  inputs.nixshare.url = "github:julian-corbet/nixshare-corbet-ch";

  outputs = { self, nixpkgs, nixshare, ... }: {
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      modules = [
        nixshare.nixosModules.default # core: schema + watchdog, zero providers
        nixshare.nixosModules.nfs-provider
        nixshare.nixosModules.cifs-provider
        nixshare.nixosModules.fscache-provider # only when any NFS share uses fsc
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
nixshare = {
  enable = true;

  # Optional: wire force-unmount alerts through nixpush. Requires
  # github:julian-corbet/nixpush-corbet-ch's own module to be imported
  # too -- nixshare has no hard dependency on it (see
  # `watchdog.alertCommand`'s own option doc), this is just the intended
  # pairing.
  watchdog.alertCommand =
    config.nixpush.lib.mkSendCommand { channel = "alerts"; priority = "urgent"; };

  shares.example = {
    protocol = "nfs";
    peer = "storage-host"; # a nixnet.peers."storage-host" entry -- see below
    remotePath = "/export/example";
    mountpoint = "/mnt/example";
    cacheSettings = {
      actimeo = "60";
      fsc = "true"; # persistent local cachefilesd cache -- per share, see below
    };
  };

  shares.backups = {
    protocol = "cifs";
    peer = "storage-host";
    remotePath = "backups"; # SMB share name, no leading slash
    mountpoint = "/mnt/backups";
    credentialsFile = "/run/secrets/nixshare-backups.cred"; # username=/password=, sops/agenix-rendered
  };
};

# `fsc` needs a local cache daemon. The NixOS provider uses NixOS's native
# cachefilesd service; a system-manager host uses the matching adapter below.
nixshare.fscache = {
  enable = true;
  cacheDir = "/var/cache/fscache";
};

# The peer named above, so "storage-host" inherits LAN/overlay failover --
# see github:julian-corbet/nixnet-corbet-ch's own README for the full
# option surface. nixshare only needs the name to already be
# NSS-resolvable; it neither requires nor knows about nixnet directly.
nixnet.enable = true;
nixnet.peers."storage-host" = {
  hostnames = [ "storage-host" ];
  transports = [
    { address = "192.0.2.10"; priority = 10;
      probe = { method = "tcp"; port = 2049; }; } # LAN, preferred
    { address = "198.51.100.10"; priority = 50;
      probe = { method = "tcp"; port = 2049; }; } # overlay, fallback
  ];
  onAllDown = "lastKnownGood"; # right call for a soft-mounted, retry-tolerant share
};
```

```console
$ systemctl status nixshare-watchdog.timer
● nixshare-watchdog.timer - Poll nixshare automounts for stuck establish attempts
     Loaded: loaded
     Active: active (waiting)
    Trigger: n/s left

$ ls /mnt/example        # first access triggers the automount, transparently
...

# Simulate the failure this project exists for: the peer goes dark mid-mount.
# Within automountTimeoutSec of the attempt starting, the watchdog notices,
# force-lazy-unmounts it, and (if alertCommand is set) sends an alert --
# nobody has to notice the session is stuck and reach for sudo by hand.
$ journalctl -u nixshare-watchdog.service -n5
nixshare-watchdog: share 'example' (/mnt/example, unit mnt-example.mount) has been activating for 31s (>= 30s) -- force-lazy-unmounting
nixshare-watchdog: umount -f -l /mnt/example succeeded
nixshare-watchdog: ALERT: nixshare: force-unmounted stuck share 'example' at /mnt/example on example-host after 31s (threshold 30s)
```

## How the watchdog works

`nixshare-watchdog` ([pkgs/nixshare-watchdog.nix](pkgs/nixshare-watchdog.nix))
is a real, working shell tool run by `nixshare-watchdog.service`
(`Type = "oneshot"`, root, no sandboxing — see [Security](#security) for
why), fired every `watchdog.pollIntervalSec` (default `10`) by
`nixshare-watchdog.timer`. Every tick, for every configured share:

1. **Resolve the mountpoint to its systemd unit.** `systemd-escape --path
   --suffix=mount "$mountpoint"` — the real command, not a hand-rolled
   reimplementation of systemd's path-escaping (deliberately runtime, not
   Nix-eval-time, so it needs nothing from `system-manager`'s smaller
   module-argument surface — see `experiments/README.md` #003).
2. **Check if an attempt is even in flight.** `systemctl show -p
   ActiveState --value "$unit"` — if it isn't `activating`, there's
   nothing to do; move on to the next share. This is a fresh query every
   tick, not a cache — the watchdog carries no state of its own between
   invocations at all.
3. **Measure how long it's been in flight.** `systemctl show -p
   InactiveExitTimestamp --value "$unit"` (the moment it left `inactive`,
   i.e. began trying to establish) against the current time.
4. **If that duration has crossed the share's own
   `automountTimeoutSec`:** force-lazy-unmount it — `umount -f -l
   "$mountpoint"` — **directly**, at the VFS level. This is the crucial
   design point: it does *not* go through `systemctl stop` or try to kill
   the blocked `mount(8)` helper process first. A mount attempt stuck
   against a dead peer is typically blocked in an *uninterruptible* kernel
   wait — not even `SIGKILL` frees it, which is exactly why systemd's own
   `TimeoutSec=` (`establishTimeoutSec`, applied by every provider) isn't
   sufficient by itself: it can send a kill signal, but it can't make a
   D-state process die. `umount -f -l` sidesteps that entirely by
   detaching the mountpoint from the namespace immediately, independent of
   whatever the stuck helper process is still doing kernel-side — the
   exact effect of the manual `sudo umount -f -l` recovery this replaces,
   just automatic and proactive instead of manual and reactive.
5. **Clean up and alert.** `systemctl reset-failed` on the unit (courtesy;
   harmless if it never actually reached `failed`), then — if
   `watchdog.alertCommand` is configured — fire it with a message
   describing what happened. A failed alert never blocks or reverts the
   recovery: the `umount` already happened by the time alerting is even
   attempted.

The watchdog is completely protocol-blind: it never knows or cares whether
a share is NFS or CIFS (see `CONTRIBUTING.md`'s ground rules) — it only
ever operates on `(name, mountpoint, automountTimeoutSec)` triples read
from `/etc/nixshare/watchdog.json`, the one JSON file `modules/core.nix`
renders. That file is the entire interface between Nix and the watchdog
script, the same shape as nixnet's own `/etc/nixnet/config.json` contract.

## How the health monitor works

The watchdog above catches a mount that never **establishes**. There is a
second failure mode it structurally cannot see: a mount that established
perfectly, is `active`, whose files read back correctly — and where every
RPC takes seconds. systemd sees nothing wrong, so no unit ever leaves
`active` and no watchdog fires. The session is unusable anyway.

Measured on a real client during the incident this was written for:

| operation | on the client | same op server-side |
|---|---|---|
| one `stat()` | **3263 ms** | 0.075 ms |
| one `touch()` | **1947 ms** | — |
| 200 small creates | **382 s** | 15 ms |

…while `ping` to the server was 3.4 ms, and `nfsstat -rc` showed
**retrans=1 out of 5,075,060 calls**. Nothing was retrying or failing; every
RPC simply stalled before it went out. The kernel's only complaint was
`SUNRPC: reached max allowed number (1) did not add transport to server`.
The trigger was a metadata storm against the mount (a recursive `chown` over
a git object store — ~10⁵ failing per-file operations). It never recovered
on its own.

`nixshare.health` probes each **already-established** mount on a
timer, and escalates only on a sustained stall:

1. **Probe** — two independent checks per mounted share, each hard-bounded by
   `probeTimeoutSec`; slower than `degradedLatencyMs` on *either* counts as
   degraded. The first is a `stat()` of a name guaranteed not to exist, so it
   can never be served from the attribute cache (`lookupcache=positive`
   caches only successful lookups) — without this, a mountpoint something
   else keeps touching can stay cache-warm for an entire incident and the
   probe never forces a live RPC at all. The second reads a names-only,
   unsorted directory listing from the mountpoint (`ls -U1 --color=never`), because
   a wedge confined to READDIRPLUS has been observed leaving plain
   `stat()`/read/write on the same mount working normally for hours — a probe
   built from `stat()` alone cannot see that class regardless of tuning. It
   deliberately does not use a full `ls -la`: that stats every child and, on
   a ZFS `crossmnt` tree, can cross many filesystems and manufacture seconds
   of cold export-cache work. The second check is a narrower guarantee than
   the first: it targets the mountpoint itself rather than a target
   constructed to defeat caching, so on a share something else scans within
   `actimeo`, it can still read from a warm directory-page cache — a known,
   stated gap, not a silent one (see `pkgs/nixshare-health.nix`'s header).
   Both checks assume this provider's
   `lookupcache=positive`/`actimeo` defaults; CIFS shares run the same
   probe without an equivalent documented guarantee.
2. **Hysteresis** — `consecutiveFailures` bad ticks in a row before acting.
   A big copy, a cold cache or a scrub on the server produces one slow tick,
   never a sustained one; the client wedge never clears on its own, so
   waiting costs nothing.
3. **The gate** — is the server actually reachable on its own port (2049 /
   445)? A dead server and a wedged client look identical from the
   mountpoint. If the server is down this **alerts and stops**: tearing down
   mounts would achieve nothing except fighting the automount that is trying
   to re-establish them.
4. **Cure**, bounded by `recovery`:
   `alert` → report only · `remount` → restart that peer's mount units ·
   `reset-client` → if a remount did not help, rebuild the shared NFS client.

### Why recovery is grouped by peer, not by share

This is the part that is worth knowing, because the obvious fix does not
work. NFS keeps **one `nfs_client` per server**, shared by every mount of
that server (`/proc/fs/nfsfs/servers`, `USE` column). Unmounting a single
mountpoint leaves that refcount non-zero, so the remount reattaches to the
*same wedged client* and nothing changes — confirmed by hand during the
incident, twice.

The client is destroyed only when **every** mount of that server is gone
**and** the fscache cookies pinning it are released. So `reset-client` stops
all of the peer's mounts and automounts, stops `cachefilesd`, unloads the
`cachefiles` module, and then waits for the captured client and volume rows
and all of its live TCP/2049 sockets to disappear before bringing anything
back. A successful `umount -f -l` only proves namespace detachment: an open
reference can keep the old client alive. If that kernel state remains after
`health.resetTeardownTimeoutSec`, the monitor restores the mounts but reports
`RESET INCOMPLETE` with separate client, volume, and socket counts. It never
calls that path a complete client reset. That is why the config is rendered
as peer groups rather than a flat share list: a per-share view makes the only
effective cure unexpressible.

`reset-client` only ever runs for `protocol = "nfs"`, only after a plain
remount has already been tried and failed, and never when the server is
unreachable. `cooldownSec` bounds how often it may run, so a cure that
does not help degrades into an alert rather than a teardown loop.

**This has a hard prerequisite, and the monitor checks it for you.** Because
the client is shared per server, `reset-client` can only destroy it if
*every* live mount of that server goes down together. Any mount nixshare
does not know about — a different export of the same server, a hand-rolled
`systemd.mount`, an `/etc/fstab` line — holds the refcount above zero, and
the reset becomes a silent no-op that reports success and changes nothing.
Before tearing anything down the monitor lists the mounts of that server it
is *not* covering and says so, and if the cure then fails it names them as
the likely cause. Declare them as shares of the same `peer` (they need no
other change) and recovery works.

On one real box, seven mounts of the same server — including a completely
different export — all shared a single `nfs_client`; declaring only one of
them would have made recovery impossible while looking like it ran.

## Options

`nixshare.*` (core — [modules/core.nix](modules/core.nix)):

- `enable` — turn nixshare on: renders `/etc/nixshare/watchdog.json` and
  starts the watchdog timer.
- `archPackages` — read-only official-Arch package intent for a
  system-manager host's Pacman reconciler. It is empty unless an active client
  provider needs packages; do not hand-maintain `nfs-utils` or `cifs-utils`
  alongside it.
- `aurPackages` — read-only AUR package intent for the AUR half of that
  reconciler. `cachefilesd` belongs here, not in an official-repository list.
- `establishTimeoutSec` (default `15`) — every provider's `.mount` unit
  `TimeoutSec=`. Bounds a normal failure fast; does not by itself free a
  genuinely stuck attempt (see [How the watchdog works](#how-the-watchdog-works)).
- `shares.<name>.protocol` — `"nfs"` or `"cifs"`. Requires the matching
  `nfs-provider`/`cifs-provider` module imported (asserted).
- `shares.<name>.peer` — a name, not a raw address; conventionally a
  [nixnet](https://github.com/julian-corbet/nixnet-corbet-ch)
  `nixnet.peers.<name>` entry, but any NSS-resolvable name works.
- `shares.<name>.remotePath` — NFS export path, or CIFS share name (no
  leading slash).
- `shares.<name>.mountpoint` — local mount point.
- `shares.<name>.automountTimeoutSec` (default `30`) — the watchdog's
  per-share threshold; must exceed `establishTimeoutSec` (asserted). See
  `experiments/README.md` #001.
- `shares.<name>.automountIdleTimeoutSec` (default `600`) — idle-teardown
  bound (`automountConfig.TimeoutIdleSec`).
- `shares.<name>.credentialsFile` — cifs only; runtime path to a
  `username=`/`password=` file, never copied into the store.
- `shares.<name>.cacheSettings` — freeform, protocol-specific tuning
  (shape opaque to core, same pattern as nixpush's `channels.<name>.settings`);
  see each provider module for its recognized keys.
- `shares.<name>.extraOptions` — extra raw `mount(8)` options appended
  verbatim.
- `watchdog.enable` (default `true`), `.pollIntervalSec` (default `10`,
  see `experiments/README.md` #002), `.package` (override to pin/patch).
- `watchdog.alertCommand` — a shell command prefix the watchdog appends a
  message to and runs on every force-unmount; intended to be filled from
  nixpush's `mkSendCommand` (see Quickstart), not a hard dependency.
- `health.resetTeardownTimeoutSec` (default `30`) — bounded wait between
  force-lazy-unmount and remount during `reset-client`. Completion requires
  the target NFS client, its volumes, and live TCP/2049 transports to vanish;
  retained state produces a typed incomplete-reset alert instead.

`nixshare.providers.*` — internal registry, set by provider
modules, not meant to be set directly.

`modules/providers/nfs.nix` — recognized `cacheSettings` keys: `nfsvers`
(default `4.2`), `timeo` (default `50`), `retrans` (default `3`),
`actimeo` (default `60`), `lookupcache` (default `positive`), `nconnect`
(default `8`), `fsc` (`"true"`/`"false"`, default `"false"`), `softreval`
(`"true"`/`"false"`, default `"false"`). Always mounts `soft` (never `hard`
— see the design note below) with `nofail`.

`softreval` is not a throughput knob. While the server is reachable it changes
nothing, because revalidation simply succeeds. It matters only once
revalidation has timed out: the client keeps serving paths and attributes it
already holds instead of failing. On a plain `soft` mount an outage makes even
a `stat()` on an already-cached path fail after the retrans budget — which is
how a desktop session, which stats every mountpoint at login, stalls on data
the client is already holding. Operations that genuinely need the server still
time out and error after `retrans`, so the bounded-failure property `soft`
exists to provide is preserved rather than traded away. `nfs(5)` also names
unmounting a tree from a permanently-dead server as a motivating case — the
same stuck-teardown class the watchdog above exists to survive.

**`fsc` is genuinely per-share — but concurrent establishment can leak it.**
Verified by remounting shares one at a time and reading the live flag from
`/proc/mounts`: each share honours its own declaration in both directions.
What does *not* survive is parallel setup. On a nine-share host, the four
shares still mounted from boot carried `fsc` despite their units never
asking for it — exactly the set that established simultaneously when the
desktop session stat'd every mountpoint at login. A mount with no `fsc` in
its own options can come up cloned from a superblock belonging to one that
has it, and the result is invisible in the unit file; only `/proc/mounts`
and `/proc/fs/nfsfs/volumes` show it. Remounting that share alone fixes it
until the next boot.

That is a runtime race, not a declaration error, so there is no eval-time
guard for it. The reliable mitigation is placement: keep `fsc = "true"` off
any share that participates in the login-time mount storm, and put it on
the big, cold, deliberately-accessed trees instead.

Worth knowing before turning it on: FS-Cache accelerates **data** reads
only. It does nothing for `OPEN`/`GETATTR`/`LOOKUP`/`READDIR`, and on a
metadata-bound workload it is not neutral — it turns every file the client
touches into a cookie lifecycle on the unbound `fscache` workqueue. On a
tree-walk-heavy host that measured 163k `OPEN` against 18 `READ` RPCs, that
came to 579k cookie acquisitions in 26 minutes for 447 cache writes, and
three concurrent recursive greps put >1000 `kworker/uNN:M-fscache` threads
into D-state at load average 341. Cache large files you re-read; do not
cache a source tree you mostly walk.

`fscache-provider` adds `nixshare.fscache`: `enable`, `cacheDir`, `tag`,
and the `watermarks.{brun,bcull,bstop,frun,fcull,fstop}` percentages. It
asserts that the run/cull/stop bands are ordered correctly, loads the
`cachefiles` kernel module, and makes a share that asks for `fsc` fail
evaluation unless this daemon is enabled. NixOS uses its native
`services.cachefilesd` module; system-manager declares `/etc/cachefilesd.conf`
and reconciles Arch's cachefilesd unit after the host package reconciler has
installed it.

`modules/providers/cifs.nix` — recognized `cacheSettings` keys: `vers`
(default `3.1.1`), `cache` (default `strict`). Falls back to the `guest`
mount option when `credentialsFile` is unset.

**Design note — why two providers, one schema:** NFS and CIFS mount option
shapes genuinely differ (`actimeo`/`fsc`/`nconnect` have no CIFS
equivalent; `credentials=`/`cache=` have no NFS equivalent), so a single
`types.enum`-dispatched mount-string builder inside core would just be an
`if protocol == "nfs"` branch wearing a trenchcoat. Splitting it into two
provider modules under one shared schema (`peer`/`remotePath`/`mountpoint`/
timeouts/watchdog coverage) keeps core protocol-blind and mirrors the
"core + pluggable provider" shape nixnet and nixpush both already use —
see `CONTRIBUTING.md` for the exact three-step contract a provider module
follows.

## Non-NixOS hosts (via `system-manager`)

`nixosModules.*` providers use NixOS-native filesystem and cache service
options. For a non-NixOS Linux box applying config with
[numtide/system-manager](https://github.com/numtide/system-manager)
instead, import `systemManagerModules.*` instead — the same schema with
matching platform adapters:

```nix
{
  inputs.nixshare.url = "github:julian-corbet/nixshare-corbet-ch";
}
imports = [
  inputs.nixshare.systemManagerModules.core
  inputs.nixshare.systemManagerModules.nfs-provider
  inputs.nixshare.systemManagerModules.cifs-provider
  inputs.nixshare.systemManagerModules.fscache-provider
];
nixshare.enable = true;
nixshare.fscache.enable = true;

# The host reconciler installs packages; Nixshare then marks its selected
# packages explicit so unrelated dependency changes cannot remove them.
nixarch.packages.pacman = config.nixshare.archPackages;
nixarch.packages.aur = config.nixshare.aurPackages;
nixshare.systemManager.packageReconcilerUnit = "nixarch-packages-reconcile.service";
# ... same options as above
```

The system-manager backend writes only declarative `/etc` state and systemd
units. The host owns the official-repository and AUR package transactions,
while Nixshare's idempotent ownership unit records its selected packages as
explicit after that transaction.
Its FS-Cache bridge then enables and restarts the distribution-owned cachefilesd
unit, so package installation, ownership, configuration, kernel-module loading,
and daemon lifecycle all converge from Git on every activation.

## Security

`nixshare-watchdog.service` runs as **root, with no sandboxing directives**
— no `ProtectSystem`, no `ProtectHome`, no `PrivateTmp`, none of the usual
NixOS-module hardening. This is deliberate, not an oversight: the unit's
entire purpose is a `umount -f -l` call that must land on the **host's
real, shared mount namespace** — the one the user's actual login session
is stuck in. Systemd's usual sandboxing directives achieve their
protection by giving a unit its own *private* mount namespace (slave
propagation: changes on the host flow in, but the unit's own mount/unmount
calls never flow back out) — silently turning every force-unmount into a
no-op as far as the real, stuck session is concerned. Root and unsandboxed
here is load-bearing, not lax.

Every other nixshare-managed unit (`systemd.mounts`/`.automounts` entries
built by the provider modules) carries no elevated privilege beyond what
the kernel's own `mount.nfs`/`mount.cifs` helpers already require — the
same privilege level any ordinary `fstab`-driven mount runs at.

## Repository layout

| Path | What |
|---|---|
| `flake.nix` | Core plus NFS, CIFS, and FS-Cache client providers for NixOS and system-manager; NixOS-only export providers; checks and packages |
| `modules/core.nix` | `shares`/`watchdog` schema, provider registry, watchdog timer + JSON render |
| `modules/providers/nfs.nix` | NFS `systemd.mounts`/`.automounts` generation |
| `modules/providers/cifs.nix` | CIFS `systemd.mounts`/`.automounts` generation |
| `modules/providers/fscache.nix` | Portable FS-Cache policy schema and package intent |
| `modules/nixos/`, `modules/system-manager/` | Plane-specific native filesystem/cache implementations |
| `pkgs/nixshare-watchdog.nix` | The watchdog script itself (real logic, see "How the watchdog works") |
| `experiments/` | Throwaway trials, dated Question/Hypothesis/Method/Status entries |
| `studies/` | Write-ups that changed a decision |
| `CONTRIBUTING.md` | The provider contract, concretely |
| `LICENSE` | MIT |

## Server-side exports

`nixosModules.nfs-server-provider` / `.cifs-server-provider`
(`nixshare.server.nfs` / `.cifs`) export a ZFS `sharenfs`/
`sharesmb`-carried tree matrix — kernel NFSv4 (idmapd Domain, firewall
scoping, a reconcile oneshot) and Samba (usershares, wsdd/avahi
discovery, the same reconcile pattern). Deliberately **not** the fancier
unified `nixshare.exports.<name>` schema once speculated here as
the "natural v2 shape" — these two providers are a direct relocation of a
real, already-running production module, kept close to its original
shape rather than redesigned, so a unified unmount/export schema
generalizing across drastically different NFS/Samba option surfaces
remains a possible future refinement, not something either provider
commits to today. nixosModules-only: `services.nfs.server`/
`services.samba`/`services.avahi`/`services.samba-wsdd` have no
system-manager equivalent.

### The whole path, server to client — read this before reasoning about coverage

The two halves compose into one chain, and the middle of it is not obvious
from either end. Written out once, explicitly, because reasoning from the
usual NFS assumptions gets it wrong:

```
  Nix declares          nixshare.server.nfs.sharenfs = { "pool/tree" = "rw=…,crossmnt"; … }
        │
        ▼
  reconcile oneshot     zfs set sharenfs=<value> pool/tree   →   zfs share -a
        │
        ▼
  ZFS owns the table    /etc/exports.d/zfs.exports        ← the ONLY writer
                        /etc/exports stays EMPTY          ← by design, not omission
        │
        ▼
  reconcile descendants inherited sharenfs is made locally `off` on undeclared
                        ZFS filesystems below each crossmnt root; zvols and
                        explicitly declared children are skipped
        │
        ▼
  client mounts a share nixshare.shares.<name> → one .mount/.automount unit
        │
        ▼
  crossmnt does the rest the kernel IMPLICITLY exports each child with the
                        parent's options and synthesizes a client mount when a
                        process walks into a child dataset. No unit, no
                        FragmentPath, nothing declares it — and nothing can.
```

Three consequences that repeatedly mislead people (and did mislead this
project's own tooling until it was fixed):

1. **There is no `/etc/exports` to reconcile against, and that is correct.**
   The pool carries the shares as properties; the definition is the asset.
   Looking for a split between Nix and ZFS here finds nothing, because Nix
   *sets the ZFS property* — it does not compete with it.

2. **A client will have far more mounts of a server than it declares shares,
   and the number grows as the tree is browsed.** One real client went from
   7 to 53 to 124 live mounts of a single server within hours, against 9
   declared shares. This is normal, healthy `crossmnt` behaviour — not drift,
   not misconfiguration, and not something to "fix" by declaring more shares.

3. **Therefore coverage is judged by SUBTREE, never by exact mountpoint.** A
   mount at or beneath a declared share is owned by that share: tearing the
   share's subtree down removes it, and it returns on the next traversal.
   Only a mount of the same server living *outside* every declared share is a
   real coverage gap. The health monitor's stray check applies exactly this
   rule; comparing raw mountpoint strings instead would report a hundred-plus
   phantom gaps on a correctly-configured host and refuse recovery forever.

## Non-goals (v1)

- **A resident watchdog daemon.** The watchdog is a systemd timer +
  stateless oneshot, not a long-running process — see
  `pkgs/nixshare-watchdog.nix`'s own header comment for why that's
  sufficient here and doesn't need nixnetd's own "resident daemon"
  treatment.
- **Retrying or backing off a genuinely failed mount itself.** That's
  `nofail`/`_netdev`/the automount trigger's own job (and, at the address
  level, nixnet's). The watchdog's job is narrower: notice an
  establish attempt has overstayed its welcome and get it out of the way,
  nothing more.
- **Any address-resolution logic.** Explicitly out of scope, permanently
  — that's what pairing `peer` with nixnet is *for*. nixshare will never
  grow its own IP/hostname failover.

## Related projects

nixshare is one of several small, independently-usable open-source
projects sharing a common design system:
[nixnet](https://github.com/julian-corbet/nixnet-corbet-ch) (declarative
multi-uplink networking and peer address failover — nixshare's own
intended pairing for the `peer` field),
[nixpush](https://github.com/julian-corbet/nixpush-corbet-ch) (provider-
agnostic notification dispatch — nixshare's own intended pairing for
watchdog alerts), and
[nixram](https://github.com/julian-corbet/nixram-corbet-ch) (memory-
pressure tuning by declared level), among others. nixshare's own niche is
NFS/CIFS share management, both directions — client mounts +
stuck-automount recovery, and server-side exports — usable alongside any
of them, or standalone with a plain hostname/IP in `peer` and no alerting
configured at all.

## Status

The core schema, client NFS/CIFS/FS-Cache providers, two server providers
(NFS/CIFS), and the watchdog are implemented for real per the settled design — real
`systemd.mounts`/`.automounts` generation, a real force-lazy-unmount
watchdog with genuine stuck-attempt detection logic, real `services.nfs.server`/
`services.samba` exports, not stubs. The server-side providers are a
direct relocation of an already-running production module (see
[Server-side exports](#server-side-exports)); the client-side providers
have run across real hosts since their own introduction.
`experiments/README.md` tracks every default and assumption that's
reasoned, not yet measured, against a
real deployment.

## License

MIT.
