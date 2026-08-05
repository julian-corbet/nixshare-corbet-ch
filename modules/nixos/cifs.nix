# NixOS implementation of the generic CIFS client provider.
{ config, lib, ... }:

let
  cifsShares = lib.filterAttrs (_: s: s.protocol == "cifs") config.nixshare.shares;
in
{
  imports = [ ../providers/cifs.nix ];

  config = lib.mkIf (config.nixshare.enable && cifsShares != { }) {
    # NixOS owns mount.cifs and its kernel support through this native option.
    boot.supportedFilesystems = [ "cifs" ];
  };
}
