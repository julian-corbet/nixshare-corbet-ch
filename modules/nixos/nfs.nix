# NixOS implementation of the generic NFS client provider.
{ config, lib, ... }:

let
  nfsShares = lib.filterAttrs (_: s: s.protocol == "nfs") config.nixshare.shares;
in
{
  imports = [ ../providers/nfs.nix ];

  config = lib.mkIf (config.nixshare.enable && nfsShares != { }) {
    # NixOS owns mount.nfs and the required kernel support through this
    # native option. Do not put a duplicate nfs-utils in systemPackages.
    boot.supportedFilesystems = [ "nfs" ];
  };
}
