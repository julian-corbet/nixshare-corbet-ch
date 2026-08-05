# modules/providers/cifs.nix
#
# The CIFS/SMB backend: turns every `nixshare.shares.<name>`
# with `protocol = "cifs"` into a real `systemd.mounts` + `systemd.automounts`
# pair. Never imported by core.nix itself -- opt in alongside it, same
# shape as modules/providers/nfs.nix. Shared verbatim between
# nixosModules.cifs-provider and systemManagerModules.cifs-provider.
{ lib, config, ... }:

with lib;

let
  cfg = config.nixshare;

  cifsShares = filterAttrs (_: s: s.protocol == "cifs") cfg.shares;

  opt = s: key: default: s.cacheSettings.${key} or default;

  mkOptionsString = s:
    let
      vers = opt s "vers" "3.1.1";
      # "strict" is the kernel default and the safest choice for a share
      # more than one client may write to concurrently; "loose" trades
      # cache coherency for latency on a genuinely single-writer share --
      # opt in per-share via cacheSettings.cache, never assumed globally.
      cache = opt s "cache" "strict";
      base = [
        "vers=${vers}"
        "cache=${cache}"
        "noatime"
        "_netdev"
        "nofail" # a share outage must never block boot/login -- see README problem statement
      ]
      ++ (if s.credentialsFile != null
      then [ "credentials=${s.credentialsFile}" ]
      else [ "guest" ]);
    in
    concatStringsSep "," (base ++ s.extraOptions);

in
{
  config = mkIf (cfg.enable && cifsShares != { }) {
    nixshare.providers.cifs.enable = true;
    # See nfs.nix: on a system-manager host the owner of the package
    # transaction consumes this intent. NixOS gets native filesystem support
    # from its cifs-provider wrapper.
    nixshare.providers.cifs.archPackages = [ "cifs-utils" ];

    systemd.mounts = mapAttrsToList
      (_: s: {
        what = "//${s.peer}/${s.remotePath}";
        where = s.mountpoint;
        type = "cifs";
        options = mkOptionsString s;
        mountConfig = {
          # See modules/providers/nfs.nix's identical comment: this is
          # ordinary systemd-driven teardown, a different mechanism from
          # the watchdog's proactive `umount -f -l` on a stuck ESTABLISH.
          LazyUnmount = true;
          TimeoutSec = "${toString cfg.establishTimeoutSec}s";
        };
        unitConfig.StartLimitIntervalSec = 0;
      })
      cifsShares;

    systemd.automounts = mapAttrsToList
      (_: s: {
        where = s.mountpoint;
        wantedBy = [ "multi-user.target" ];
        automountConfig.TimeoutIdleSec = toString s.automountIdleTimeoutSec;
      })
      cifsShares;
  };
}
