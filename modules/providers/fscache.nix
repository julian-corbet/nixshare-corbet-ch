# FS-Cache schema shared by the NixOS and system-manager implementations.
#
# This is an NFS client provider, rather than core state: the core owns a
# protocol-blind share schema and monitors; `fsc` is an NFS-specific mount
# option whose daemon and kernel module belong with that client protocol.
{ config, lib, ... }:

with lib;

let
  cfg = config.nixshare;
  fsc = cfg.fscache;
in
{
  options.nixshare.fscache = {
    enable = mkEnableOption "the local cachefilesd daemon for NFS shares that request fsc";

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/fscache";
      description = "Absolute directory backed by the local filesystem that holds cached NFS objects.";
    };

    tag = mkOption {
      type = types.strMatching "[A-Za-z0-9_.-]+";
      default = "nixshare";
      description = "cachefilesd cache tag. Restricted to a single safe token because it is rendered into cachefilesd.conf.";
    };

    watermarks = {
      brun = mkOption {
        type = types.ints.between 0 100;
        default = 25;
        description = "Start accepting objects again when this percentage of the backing filesystem is free.";
      };
      bcull = mkOption {
        type = types.ints.between 0 100;
        default = 23;
        description = "Start culling cached objects when free space falls below this percentage.";
      };
      bstop = mkOption {
        type = types.ints.between 0 100;
        default = 21;
        description = "Stop allocating new cache objects when free space falls below this percentage.";
      };
      frun = mkOption {
        type = types.ints.between 0 100;
        default = 10;
        description = "Start accepting objects again when this percentage of inodes is free.";
      };
      fcull = mkOption {
        type = types.ints.between 0 100;
        default = 7;
        description = "Start culling cached objects when free inodes fall below this percentage.";
      };
      fstop = mkOption {
        type = types.ints.between 0 100;
        default = 3;
        description = "Stop allocating new cache objects when free inodes fall below this percentage.";
      };
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Additional cachefilesd.conf directives, appended after the managed directory, tag, and watermarks.";
    };
  };

  config = mkIf (cfg.enable && fsc.enable) {
    nixshare.providers.fscache.enable = true;
    # The package transaction remains the operating system's job. The
    # system-manager adapter publishes this list; the NixOS adapter uses the
    # native services.cachefilesd module, whose unit closes over the package.
    nixshare.providers.fscache.archPackages = [ "cachefilesd" ];

    assertions = [
      {
        assertion = hasPrefix "/" fsc.cacheDir;
        message = "nixshare.fscache.cacheDir must be an absolute path.";
      }
      {
        assertion = fsc.watermarks.brun > fsc.watermarks.bcull
          && fsc.watermarks.bcull > fsc.watermarks.bstop;
        message = "nixshare.fscache watermarks must satisfy brun > bcull > bstop.";
      }
      {
        assertion = fsc.watermarks.frun > fsc.watermarks.fcull
          && fsc.watermarks.fcull > fsc.watermarks.fstop;
        message = "nixshare.fscache inode watermarks must satisfy frun > fcull > fstop.";
      }
    ];
  };
}
