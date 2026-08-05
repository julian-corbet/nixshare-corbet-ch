# Arch package ownership for system-manager hosts.
#
# The consuming host owns installation (and any AUR policy) through its one
# reconciler. Once those packages exist, nixshare makes its selected official
# packages explicit, so a package that happened to arrive as another package's
# dependency cannot silently disappear when that unrelated dependency does.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixshare;
  sm = cfg.systemManager;
  ownership = pkgs.writeShellScript "nixshare-package-ownership" ''
    set -euo pipefail
    /usr/bin/pacman -D --asexplicit ${lib.escapeShellArgs cfg.archPackages}
  '';
in
{
  options.nixshare.systemManager.packageReconcilerUnit = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "nixarch-packages-reconcile.service";
    description = ''
      Optional systemd unit that installs `nixshare.archPackages`. When set,
      nixshare's ownership unit requires and runs after it before marking the
      selected packages explicit. The default keeps nixshare independent of a
      particular Arch package reconciler.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.archPackages != [ ]) {
    systemd.services.nixshare-package-ownership = {
      description = "nixshare: retain declared Arch client packages";
      wantedBy = [ "multi-user.target" ];
      after = lib.optional (sm.packageReconcilerUnit != null) sm.packageReconcilerUnit;
      requires = lib.optional (sm.packageReconcilerUnit != null) sm.packageReconcilerUnit;
      restartTriggers = [ ownership ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ownership;
      };
    };
  };
}
