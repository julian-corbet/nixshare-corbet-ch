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
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
services.nixshare = {
  enable = true;

  # Optional: wire force-unmount alerts through nixpush. Requires
  # github:julian-corbet/nixpush-corbet-ch's own module to be imported
  # too -- nixshare has no hard dependency on it (see
  # `watchdog.alertCommand`'s own option doc), this is just the intended
  # pairing.
  watchdog.alertCommand =
    config.services.nixpush.lib.mkSendCommand { channel = "alerts"; priority = "urgent"; };

  shares.example = {
    protocol = "nfs";
    peer = "storage-host"; # a services.nixnet.peers."storage-host" entry -- see below
    remotePath = "/export/example";
    mountpoint = "/mnt/example";
    cacheSettings = {
      actimeo = "60";
      fsc = "true"; # persistent local cachefilesd cache for this share
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

# The peer named above, so "storage-host" inherits LAN/overlay failover --
# see github:julian-corbet/nixnet-corbet-ch's own README for the full
# option surface. nixshare only needs the name to already be
# NSS-resolvable; it neither requires nor knows about nixnet directly.
services.nixnet.enable = true;
services.nixnet.peers."storage-host" = {
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

## Options

`services.nixshare.*` (core — [modules/core.nix](modules/core.nix)):

- `enable` — turn nixshare on: renders `/etc/nixshare/watchdog.json` and
  starts the watchdog timer.
- `establishTimeoutSec` (default `15`) — every provider's `.mount` unit
  `TimeoutSec=`. Bounds a normal failure fast; does not by itself free a
  genuinely stuck attempt (see [How the watchdog works](#how-the-watchdog-works)).
- `shares.<name>.protocol` — `"nfs"` or `"cifs"`. Requires the matching
  `nfs-provider`/`cifs-provider` module imported (asserted).
- `shares.<name>.peer` — a name, not a raw address; conventionally a
  [nixnet](https://github.com/julian-corbet/nixnet-corbet-ch)
  `services.nixnet.peers.<name>` entry, but any NSS-resolvable name works.
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

`services.nixshare.providers.*` — internal registry, set by provider
modules, not meant to be set directly.

`modules/providers/nfs.nix` — recognized `cacheSettings` keys: `nfsvers`
(default `4.2`), `timeo` (default `50`), `retrans` (default `3`),
`actimeo` (default `60`), `lookupcache` (default `positive`), `nconnect`
(default `8`), `fsc` (`"true"`/`"false"`, default `"false"`). Always
mounts `soft` (never `hard` — see the design note below) with `nofail`.

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

`nixosModules.core`/`.nfs-provider`/`.cifs-provider` need a real NixOS
host. For a non-NixOS Linux box applying config with
[numtide/system-manager](https://github.com/numtide/system-manager)
instead, import `systemManagerModules.*` instead — same files, same
schema:

```nix
{
  inputs.nixshare.url = "github:julian-corbet/nixshare-corbet-ch";
}
imports = [
  inputs.nixshare.systemManagerModules.core
  inputs.nixshare.systemManagerModules.nfs-provider
];
services.nixshare.enable = true;
# ... same options as above
```

nixshare only ever touches `environment.etc`, `systemd.services`/`.timers`/
`.mounts`/`.automounts`, and a rendered JSON file — none of it depends on
NixOS-only primitives (no `boot.kernel.sysctl`, no activation scripts, no
kernel command-line parameters), the same portability argument nixnet's
own README makes for its core module. This hasn't yet been confirmed
against a real `system-manager`-applied host for the `systemd.mounts`/
`.automounts` surface specifically — flagged explicitly in
`experiments/README.md` #004 rather than silently assumed.

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
| `flake.nix` | `nixosModules.core`/`.nfs-provider`/`.cifs-provider`/`.default`; same trio under `systemManagerModules.*`; `packages.nixshare-watchdog` |
| `modules/core.nix` | `shares`/`watchdog` schema, provider registry, watchdog timer + JSON render |
| `modules/providers/nfs.nix` | NFS `systemd.mounts`/`.automounts` generation |
| `modules/providers/cifs.nix` | CIFS `systemd.mounts`/`.automounts` generation |
| `pkgs/nixshare-watchdog.nix` | The watchdog script itself (real logic, see "How the watchdog works") |
| `experiments/` | Throwaway trials, dated Question/Hypothesis/Method/Status entries |
| `studies/` | Write-ups that changed a decision |
| `CONTRIBUTING.md` | The provider contract, concretely |
| `LICENSE` | MIT |

## Server-side exports

`nixosModules.nfs-server-provider` / `.cifs-server-provider`
(`services.nixshare.server.nfs` / `.cifs`) export a ZFS `sharenfs`/
`sharesmb`-carried tree matrix — kernel NFSv4 (idmapd Domain, firewall
scoping, a reconcile oneshot) and Samba (usershares, wsdd/avahi
discovery, the same reconcile pattern). Deliberately **not** the fancier
unified `services.nixshare.exports.<name>` schema once speculated here as
the "natural v2 shape" — these two providers are a direct relocation of a
real, already-running production module, kept close to its original
shape rather than redesigned, so a unified unmount/export schema
generalizing across drastically different NFS/Samba option surfaces
remains a possible future refinement, not something either provider
commits to today. nixosModules-only: `services.nfs.server`/
`services.samba`/`services.avahi`/`services.samba-wsdd` have no
system-manager equivalent.

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

The core schema, all four providers (client nfs/cifs, server nfs/cifs),
and the watchdog are implemented for real per the settled design — real
`systemd.mounts`/`.automounts` generation, a real force-lazy-unmount
watchdog with genuine stuck-attempt detection logic, real `services.nfs.server`/
`services.samba` exports, not stubs. The server-side providers are a
direct relocation of an already-running production module (see
[Server-side exports](#server-side-exports)); the client-side providers
have run against a real fleet since their own introduction.
`experiments/README.md` tracks every default and assumption that's
reasoned, not yet measured, against a
real deployment.

## License

MIT.
