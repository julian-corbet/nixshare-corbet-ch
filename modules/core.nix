# modules/core.nix
#
# nixshare's schema (services.nixshare.shares.<name>) plus the two
# protocol-agnostic supervisors: the stuck-automount `watchdog` (a mount
# that never establishes) and the `health` monitor (a mount that
# established fine and then degraded to seconds-per-RPC -- see
# pkgs/nixshare-health.nix). Shared verbatim between nixosModules.core
# and systemManagerModules.core (flake.nix) -- everything here touches
# only environment.etc, systemd.services/timers, and a rendered JSON file,
# none of which system-manager categorically can't reach (same portability
# argument nixnet's own core.nix makes).
#
# Core deliberately declares NO `systemd.mounts`/`systemd.automounts`
# itself -- NFS and CIFS have genuinely different mount option shapes
# (design note in the top-level README), so building the actual mount
# units is each protocol provider's job (modules/providers/nfs.nix,
# modules/providers/cifs.nix). A share whose `protocol` has no matching
# provider imported is a hard eval error (see the assertions below), not
# a silently-inert entry.
#
# The `peer` field is intentionally just a plain string: nixshare has NO
# address-resolution logic of its own. It builds `what = "<peer>:<path>"`
# (NFS) / `what = "//<peer>/<path>"` (CIFS) and lets ordinary NSS resolve
# `<peer>` -- which is exactly what a github:julian-corbet/nixnet-corbet-ch
# `services.nixnet.peers.<name>.hostnames` entry publishes into a
# live-managed /etc/hosts. nixshare works identically with a peer name
# resolved by nixnet, by plain DNS, or by a hand-edited /etc/hosts line --
# it has no idea which, and doesn't need to.
{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.services.nixshare;

  shareType = types.submodule {
    options = {
      protocol = mkOption {
        type = types.enum [ "nfs" "cifs" ];
        description = ''
          Which provider module builds this share's mount unit. Requires
          the matching `nixosModules.nfs-provider`/`.cifs-provider` (or
          `systemManagerModules.*`) to actually be imported -- asserted
          below, not silently ignored.
        '';
      };

      peer = mkOption {
        type = types.str;
        example = "storage-host";
        description = ''
          The share's server, named -- NOT a raw IP/hostname literal.
          Conventionally a github:julian-corbet/nixnet-corbet-ch
          `services.nixnet.peers.<name>.hostnames` entry, so this share's
          server address inherits nixnet's LAN/overlay failover for free;
          nixshare itself just concatenates this string into `what =`
          and lets NSS (files-then-DNS) resolve it. Works with any
          NSS-resolvable name -- nixnet is the intended pairing, not a
          hard dependency.
        '';
      };

      remotePath = mkOption {
        type = types.str;
        description = ''
          The path on the peer. For `protocol = "nfs"` this is the
          exported path (e.g. `/export/example`, matching whatever the
          server's `/etc/exports` publishes). For `protocol = "cifs"`
          this is the SMB share name, WITHOUT a leading slash (e.g.
          `example-share`) -- the cifs provider builds
          `//<peer>/<remotePath>` from it verbatim.
        '';
      };

      mountpoint = mkOption {
        type = types.path;
        example = "/mnt/example";
        description = "Local mount point. Created if missing (systemd's `X-mount.mkdir`-equivalent is applied by each provider).";
      };

      automountTimeoutSec = mkOption {
        type = types.ints.positive;
        default = 30;
        description = ''
          The watchdog's threshold: once a mount attempt for this share
          has been in flight (systemd `ActiveState = activating`) for at
          least this long, the watchdog force-lazy-unmounts it and fires
          an alert rather than waiting for it to resolve on its own. Must
          be greater than `services.nixshare.establishTimeoutSec`
          (asserted below) -- otherwise the watchdog could fire on an
          attempt that's still within its own normal window, not one
          that's actually stuck. See `experiments/README.md` #001 for
          the reasoning (and open question) behind the default.
        '';
      };

      automountIdleTimeoutSec = mkOption {
        type = types.ints.positive;
        default = 600;
        description = "Idle-teardown bound (`automountConfig.TimeoutIdleSec`): how long the mount may sit unused before systemd tears it back down to the automount trigger.";
      };

      credentialsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          cifs only, ignored by the nfs provider. Path to a
          runtime-readable file (sops-nix / agenix rendered, root-only)
          containing `username=...` / `password=...` / `domain=...`
          lines in Linux CIFS `credentials=` file format. Read fresh by
          the kernel's mount helper at mount time; never copied into the
          Nix store (pass an absolute runtime path, e.g.
          `/run/secrets/nixshare-example.cred`, not a Nix path literal --
          same convention as nixpush's own `secretFile`). Left `null`,
          the cifs provider falls back to `guest` -- fine for a
          genuinely public/guest-readable share, a hard error waiting to
          happen for anything else.
        '';
      };

      cacheSettings = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Protocol-specific tuning, shape opaque to core (same pattern as
          nixpush's `channels.<name>.settings`) -- each provider
          documents and defaults its own recognized keys. See
          modules/providers/nfs.nix (`actimeo`, `fsc`, `nconnect`,
          `nfsvers`, `timeo`, `retrans`, `lookupcache`) and
          modules/providers/cifs.nix (`vers`, `cache`) for the keys each
          understands. Unrecognized keys for the share's `protocol` are
          silently ignored by that provider -- set `extraOptions` instead
          for anything not covered.
        '';
      };

      extraOptions = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra raw mount(8) options appended verbatim, after everything cacheSettings produces. Escape hatch, not the primary tuning surface.";
      };
    };
  };

  # ---------------------------------------------------------------------
  # Provider registry (nixpush's `providers`/`providerDefaults` pattern,
  # adapted to a closed two-value enum instead of an open attrsOf
  # package): each provider module sets
  # `services.nixshare.providers.<protocol>.enable = true` in its own
  # `config` block when imported+enabled. Core never imports a provider
  # and never contains protocol-specific code -- it only reads this
  # registry back, in the assertion below, to catch "protocol declared,
  # no matching provider imported" at eval time instead of producing a
  # share that silently never gets a mount unit.
  # ---------------------------------------------------------------------
  providerRegistryType = types.submodule {
    options.enable = mkOption { type = types.bool; default = false; };
  };

  # Single-level `or` on purpose -- see nixpush's modules/default.nix
  # comment on exactly this trap: `cfg.providers.${x}.enable or false`
  # (a NESTED lookup before the `or`) still throws "attribute missing"
  # if `cfg.providers` has no `${x}` key at all, because `or` only
  # guards the FINAL attribute access, not the path to get there.
  # Falling back to a whole default record first sidesteps that.
  providerEnabled = protocol: (cfg.providers.${protocol} or { enable = false; }).enable;

  # ---------------------------------------------------------------------
  # Watchdog config render (design note above package.nix's own header
  # comment for the full "why shell" reasoning) -- the watchdog script
  # itself is entirely generic; every share-specific fact it needs lives
  # in this one JSON file, read fresh every tick.
  # ---------------------------------------------------------------------
  watchdogConfig = {
    shares = mapAttrsToList
      (name: s: {
        inherit name;
        mountpoint = s.mountpoint;
        automountTimeoutSec = s.automountTimeoutSec;
      })
      cfg.shares;
    alertCommand = cfg.watchdog.alertCommand;
  };

  watchdogConfigFile = pkgs.writeText "nixshare-watchdog.json" (builtins.toJSON watchdogConfig);

  watchdogPackage = pkgs.callPackage ../pkgs/nixshare-watchdog.nix { };

  # ---------------------------------------------------------------------
  # Health config render. Grouped by PEER, not by share, and that grouping
  # is the whole point: NFS keeps one `nfs_client` per server shared by
  # every mount of it (/proc/fs/nfsfs/servers, USE column), so a wedged
  # client can only be destroyed by dropping ALL of that server's mounts at
  # once. A per-share view would make the only effective cure unexpressible.
  # See pkgs/nixshare-health.nix's header for the incident this encodes.
  # ---------------------------------------------------------------------
  healthPeerGroups =
    let
      entries = mapAttrsToList (name: s: { key = "${s.peer}|${s.protocol}"; inherit name; share = s; }) cfg.shares;
      keys = lib.unique (map (e: e.key) entries);
    in
    map
      (k:
        let
          members = lib.filter (e: e.key == k) entries;
          first = (lib.head members).share;
        in
        {
          peer = first.peer;
          protocol = first.protocol;
          # The reachability gate's port: the protocol's own well-known
          # port, so "is the server actually up" is answered by the service
          # we care about rather than by ICMP (which is routinely filtered
          # independently of whether the share is serving).
          port = if first.protocol == "nfs" then 2049 else 445;
          shares = map (m: { inherit (m) name; mountpoint = m.share.mountpoint; }) members;
        })
      keys;

  healthConfig = {
    degradedLatencyMs = cfg.health.degradedLatencyMs;
    probeTimeoutSec = cfg.health.probeTimeoutSec;
    consecutiveFailures = cfg.health.consecutiveFailures;
    cooldownSec = cfg.health.cooldownSec;
    recovery = cfg.health.recovery;
    stateDir = cfg.health.stateDir;
    alertCommand = cfg.health.alertCommand;
    peers = healthPeerGroups;
  };

  healthConfigFile = pkgs.writeText "nixshare-health.json" (builtins.toJSON healthConfig);

  healthPackage = pkgs.callPackage ../pkgs/nixshare-health.nix { };

in
{
  options.services.nixshare = {
    enable = mkEnableOption "nixshare declarative NFS/CIFS shares, with a stuck-automount watchdog and a degraded-mount health monitor";

    establishTimeoutSec = mkOption {
      type = types.ints.positive;
      default = 15;
      description = ''
        Per-establish-attempt bound applied by every provider as each
        share's `.mount` unit `TimeoutSec=` -- one setting here, not
        duplicated per-provider, so it can be asserted against every
        share's `automountTimeoutSec` (core schema's own option, above).
        Bounds a normal failure (e.g. server actively refusing) fast;
        does NOT by itself save a mount attempt truly stuck in an
        uninterruptible kernel wait (systemd's own timeout sends
        SIGTERM/SIGKILL, which cannot free a process blocked in D state)
        -- that's what the watchdog's `umount -f -l` is for, since it
        acts on the VFS mount table directly and doesn't depend on the
        blocked helper process dying first.
      '';
    };

    providers = mkOption {
      type = types.attrsOf providerRegistryType;
      default = { };
      internal = true;
      description = "Populated by provider modules confirming their protocol is available. Not meant to be set directly.";
    };

    shares = mkOption {
      type = types.attrsOf shareType;
      default = { };
      description = "Declarative NFS/CIFS share definitions -- client-side mount + automount + watchdog coverage. See README.md Quickstart for a worked example.";
    };

    watchdog = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Run the stuck-automount watchdog timer. On by default whenever nixshare itself is enabled -- this is the whole point of the project.";
      };

      pollIntervalSec = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "How often the watchdog checks every configured share's mount unit state. See experiments/README.md #002.";
      };

      alertCommand = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = literalExpression ''
          config.services.nixpush.lib.mkSendCommand { channel = "alerts"; priority = "urgent"; }
        '';
        description = ''
          A full shell command PREFIX (already including any flags,
          shell-escaped) that the watchdog appends one trailing quoted
          message argument to and runs whenever it force-unmounts a
          stuck share. `null` (default): force-unmounts still happen and
          are still logged to the journal, just never alerted externally.

          nixshare has no hard dependency on
          github:julian-corbet/nixpush-corbet-ch -- any shell command
          that accepts a trailing message string works -- but
          `config.services.nixpush.lib.mkSendCommand { ... }` (nixpush's
          own Nix-level helper, see its README) is the intended, tested
          way to fill this in; see this repo's own README Quickstart for
          a worked example.
        '';
      };

      package = mkOption {
        type = types.package;
        default = watchdogPackage;
        description = "The nixshare-watchdog executable. Override only to pin/patch a build.";
      };
    };

    # -------------------------------------------------------------------
    # health: the OTHER failure mode. watchdog covers a mount that never
    # establishes; this covers one that established fine and then went
    # useless -- `active`, readable, and taking seconds per RPC. systemd
    # sees nothing wrong, so the watchdog structurally cannot fire.
    # -------------------------------------------------------------------
    health = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run the mount-health monitor. On by default for the same reason
          the watchdog is: an unattended client that silently degrades to
          seconds-per-RPC is exactly the failure this project exists to
          keep off the user's session. It only ever acts on a mount that is
          already `active`, only after `consecutiveFailures` sustained bad
          probes, and only when the server is provably reachable.
        '';
      };

      pollIntervalSec = mkOption {
        type = types.ints.positive;
        default = 60;
        description = ''
          How often to probe each established mount. Much slower than the
          watchdog's poll on purpose: this looks for a SUSTAINED stall, not
          a moment of it, and every tick costs one real metadata round-trip
          per mounted share.
        '';
      };

      degradedLatencyMs = mkOption {
        type = types.ints.positive;
        default = 500;
        description = ''
          A single `stat()` on the mountpoint slower than this counts the
          probe as degraded. Healthy is single-digit milliseconds even over
          a WireGuard overlay; the real incident this defends against
          measured 3263 ms for one stat. 500 leaves two orders of magnitude
          of headroom over healthy while still catching that by a factor of
          six, so ordinary load spikes do not register.
        '';
      };

      probeTimeoutSec = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Hard bound on a single probe, so a fully-hung mount cannot wedge the monitor itself. A timeout counts as the most degraded reading possible.";
      };

      consecutiveFailures = mkOption {
        type = types.ints.positive;
        default = 3;
        description = ''
          How many consecutive degraded ticks before recovery is attempted.
          Hysteresis is what keeps a big copy, a cold cache, or a scrub on
          the server from triggering a teardown; the client wedge this
          targets does not clear on its own, so waiting costs nothing.
        '';
      };

      cooldownSec = mkOption {
        type = types.ints.positive;
        default = 900;
        description = "Minimum interval between recovery attempts for the same peer. Bounds the damage if recovery does not actually help -- the monitor alerts and waits rather than looping a disruptive teardown.";
      };

      recovery = mkOption {
        type = types.enum [ "alert" "remount" "reset-client" ];
        default = "reset-client";
        description = ''
          How far recovery may escalate.

          `alert`        : report only, change nothing.
          `remount`      : restart the peer's own mount units, and stop there.
          `reset-client` : if a remount did not help, additionally destroy
                           and rebuild the shared NFS client -- stop every
                           mount AND automount of that peer, release the
                           fscache cookies pinning it (stop cachefilesd,
                           unload `cachefiles`), then bring it all back.

          The default is the strongest because the weaker ones do not
          actually cure the failure being targeted: a wedged `nfs_client` is
          shared per SERVER, so remounting one share reattaches to the same
          broken client and changes nothing (confirmed by hand during the
          incident in pkgs/nixshare-health.nix's header). `reset-client`
          only ever runs on `protocol = "nfs"`, and never when the server is
          unreachable.
        '';
      };

      stateDir = mkOption {
        type = types.path;
        default = "/run/nixshare";
        description = "Where the monitor keeps its cross-tick state (consecutive-failure counts, cure cooldown stamps). On tmpfs by design -- a reboot clears client state anyway, so stale counters must not survive one.";
      };

      alertCommand = mkOption {
        type = types.nullOr types.str;
        default = cfg.watchdog.alertCommand;
        defaultText = literalExpression "config.services.nixshare.watchdog.alertCommand";
        description = "Alert command, same contract as the watchdog's; defaults to whatever the watchdog already uses so a host configures notification once.";
      };

      recoveryTimeoutSec = mkOption {
        type = types.ints.positive;
        default = 300;
        description = ''
          `TimeoutStartSec` for the health unit, and it is safety-critical
          rather than a tuning knob. systemd's stock `DefaultTimeoutStartSec`
          is **15 seconds**; a `reset-client` teardown runs against a WEDGED
          server connection where every `systemctl stop` is itself slow, and
          the real incident's manual teardown took well over a minute. At the
          default, systemd SIGTERMs the tool mid-teardown -- with the mounts
          AND their automounts stopped and nothing left to re-trigger them.
          The tool defends itself (an EXIT/TERM trap restores what it tore
          down, and a leftover teardown record is replayed on the next tick),
          but the bound has to be generous enough that the interruption does
          not happen routinely in the first place.
        '';
      };

      package = mkOption {
        type = types.package;
        default = healthPackage;
        description = "The nixshare-health executable. Override only to pin/patch a build.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions =
      (
        let mountpoints = mapAttrsToList (_: s: s.mountpoint) cfg.shares;
        in [{
          assertion = length mountpoints == length (unique mountpoints);
          message = ''
            services.nixshare.shares has two different shares declaring the
            same mountpoint -- two systemd automount units racing to own
            the same path is exactly the kind of failure nixshare exists
            to prevent, not reproduce. Give each share its own mountpoint.
          '';
        }]
      )
      ++ (mapAttrsToList
        (name: s: {
          assertion = providerEnabled s.protocol;
          message = ''
            services.nixshare.shares.${name}.protocol is "${s.protocol}",
            but no matching provider module is imported/enabled. Import
            nixosModules.${s.protocol}-provider (or
            systemManagerModules.${s.protocol}-provider on a
            system-manager host) alongside nixosModules.core. Registered
            providers: ${
              if cfg.providers == { }
              then "(none)"
              else concatStringsSep ", " (attrNames (filterAttrs (_: p: p.enable) cfg.providers))
            }
          '';
        })
        cfg.shares)
      ++ (mapAttrsToList
        (name: s: {
          assertion = s.automountTimeoutSec > cfg.establishTimeoutSec;
          message = ''
            services.nixshare.shares.${name}.automountTimeoutSec
            (${toString s.automountTimeoutSec}s) must be greater than
            services.nixshare.establishTimeoutSec
            (${toString cfg.establishTimeoutSec}s) -- otherwise the
            watchdog could force-unmount an attempt that's still within
            its own normal establish window, not one that's actually stuck.
          '';
        })
        cfg.shares);

    environment.etc."nixshare/watchdog.json".source = watchdogConfigFile;
    environment.etc."nixshare/health.json" = mkIf cfg.health.enable { source = healthConfigFile; };

    systemd.timers.nixshare-health = mkIf cfg.health.enable {
      description = "Probe established nixshare mounts for a degraded (but mounted) server connection";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.health.pollIntervalSec}s";
        OnUnitActiveSec = "${toString cfg.health.pollIntervalSec}s";
        Unit = "nixshare-health.service";
      };
    };

    systemd.services.nixshare-health = mkIf cfg.health.enable {
      description = "nixshare health: detect and cure a degraded-but-mounted NFS client";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.health.package}/bin/nixshare-health";
        # See recoveryTimeoutSec: the stock 15s default lands SIGTERM inside
        # the teardown window, which is precisely how this tool would strand
        # the mounts it exists to rescue.
        TimeoutStartSec = "${toString cfg.health.recoveryTimeoutSec}s";
        # The state the crash-recovery path replays lives here, and tmpfs is
        # correct: after a reboot the automounts re-establish on their own, so
        # a stale teardown record must not survive one.
        RuntimeDirectory = "nixshare";
        RuntimeDirectoryPreserve = "yes";
        # Unsandboxed for the SAME load-bearing reason as the watchdog (see
        # its comment below): recovery performs `umount -f -l` and restarts
        # .mount units, and both must land in the HOST's shared mount
        # namespace. Any of systemd's namespace-based protections would give
        # this unit a private mount namespace, silently turning the entire
        # recovery into a no-op that still reports success. It additionally
        # needs to unload a kernel module (`cachefiles`) to release the
        # fscache cookies pinning the wedged client, which is likewise
        # incompatible with the usual hardening set.
      };
    };

    systemd.timers.nixshare-watchdog = mkIf cfg.watchdog.enable {
      description = "Poll nixshare automounts for stuck establish attempts";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.watchdog.pollIntervalSec}s";
        OnUnitActiveSec = "${toString cfg.watchdog.pollIntervalSec}s";
        Unit = "nixshare-watchdog.service";
      };
    };

    systemd.services.nixshare-watchdog = mkIf cfg.watchdog.enable {
      description = "nixshare watchdog: force-unmount a stuck automount before it hangs the session";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.watchdog.package}/bin/nixshare-watchdog";
        # Deliberately NO ProtectSystem/ProtectHome/PrivateTmp/etc. This
        # unit's entire purpose is a `umount -f -l` that MUST propagate to
        # the HOST's real, shared mount namespace -- the one the user's
        # login shell is actually stuck in. Most of systemd's usual
        # sandboxing directives achieve their protection by giving the
        # unit its own PRIVATE mount namespace (slave propagation: host
        # changes flow in, but the unit's own mount/unmount calls never
        # flow back out) -- silently turning every force-unmount into a
        # no-op as far as the real session is concerned. Root and
        # unsandboxed here is a deliberate, load-bearing choice, not an
        # oversight -- see README.md Security.
      };
    };
  };
}
