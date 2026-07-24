# modules/providers/nfs.nix
#
# The NFS backend: turns every `services.nixshare.shares.<name>` with
# `protocol = "nfs"` into a real `systemd.mounts` + `systemd.automounts`
# pair. Never imported by core.nix itself -- opt in alongside it, same
# shape as nixnet's provider modules. Shared verbatim between
# nixosModules.nfs-provider and systemManagerModules.nfs-provider.
{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixshare;

  nfsShares = filterAttrs (_: s: s.protocol == "nfs") cfg.shares;

  # `cacheSettings` is opaque freeform at the core schema level (see
  # core.nix) -- this is where those keys actually get interpreted, with
  # the recognized-key list and defaults documented once, here.
  opt = s: key: default: s.cacheSettings.${key} or default;

  mkOptionsString = s:
    let
      nfsvers = opt s "nfsvers" "4.2";
      timeo = opt s "timeo" "50"; # deciseconds; 50 = 5s per RPC retry
      retrans = opt s "retrans" "3";
      actimeo = opt s "actimeo" "60";
      lookupcache = opt s "lookupcache" "positive";
      nconnect = opt s "nconnect" "8";
      useFsc = (opt s "fsc" "false") == "true";
      base = [
        "nfsvers=${nfsvers}"
        "soft" # required: a "hard" mount is exactly what the watchdog exists to route around -- see README's design note
        "timeo=${timeo}"
        "retrans=${retrans}"
        "noatime"
        "_netdev"
        "nofail" # a share outage must never block boot/login -- see README problem statement
        "actimeo=${actimeo}"
        "lookupcache=${lookupcache}"
        "nconnect=${nconnect}"
      ] ++ optional useFsc "fsc";
    in
    concatStringsSep "," (base ++ s.extraOptions);

in
{
  config = mkIf (cfg.enable && nfsShares != { }) {
    services.nixshare.providers.nfs.enable = true;

    systemd.mounts = mapAttrsToList
      (_: s: {
        what = "${s.peer}:${s.remotePath}";
        where = s.mountpoint;
        type = "nfs4";
        options = mkOptionsString s;
        mountConfig = {
          # LazyUnmount here covers ordinary systemd-driven teardown
          # (idle timeout, service stop, shutdown) -- a non-lazy stop
          # against a degraded peer can itself hang. It's a DIFFERENT
          # mechanism from the watchdog's own explicit `umount -f -l`,
          # which handles a stuck ESTABLISH attempt, proactively, before
          # a teardown would even be reached.
          LazyUnmount = true;
          TimeoutSec = "${toString cfg.establishTimeoutSec}s";
        };
        # An outage must not permanently disarm the automount by tripping
        # systemd's default start-rate-limit (5 starts/10s) -- a single
        # bad peer window shouldn't cost every later automount trigger
        # for the rest of the boot.
        unitConfig.StartLimitIntervalSec = 0;
      })
      nfsShares;

    systemd.automounts = mapAttrsToList
      (_: s: {
        where = s.mountpoint;
        wantedBy = [ "multi-user.target" ];
        automountConfig.TimeoutIdleSec = toString s.automountIdleTimeoutSec;
      })
      nfsShares;
  };
}
