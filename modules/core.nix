# modules/core.nix
#
# nixshare's schema (services.nixshare.shares.<name>) plus the
# protocol-agnostic watchdog. Shared verbatim between nixosModules.core
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

in
{
  options.services.nixshare = {
    enable = mkEnableOption "nixshare declarative NFS/CIFS shares with stuck-automount watchdog";

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
