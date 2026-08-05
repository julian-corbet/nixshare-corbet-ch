# NixOS implementation of the shared FS-Cache schema.
{ config, lib, ... }:

let
  fsc = config.nixshare.fscache;
  w = fsc.watermarks;
in
{
  imports = [ ../providers/fscache.nix ];

  config = lib.mkIf (config.nixshare.enable && fsc.enable) {
    # Native NixOS service: it owns the cachefilesd package and lifecycle.
    services.cachefilesd = {
      enable = true;
      cacheDir = fsc.cacheDir;
      extraConfig = ''
        tag ${fsc.tag}
        brun ${toString w.brun}%
        bcull ${toString w.bcull}%
        bstop ${toString w.bstop}%
        frun ${toString w.frun}%
        fcull ${toString w.fcull}%
        fstop ${toString w.fstop}%
        ${fsc.extraConfig}
      '';
    };
    boot.kernelModules = [ "cachefiles" ];
  };
}
