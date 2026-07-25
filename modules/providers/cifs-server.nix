# modules/providers/cifs-server.nix
#
# The CIFS/SMB server side (README's documented "v2 addition"): smbd +
# ZFS `sharesmb`-driven usershares, nmbd/WSD/mDNS discovery, and a
# reconcile oneshot that applies a caller-supplied list of `sharesmb`
# trees to the pool. Relocated verbatim from a private, ad-hoc
# "nixnas.smb"-namespaced module in the infra repo (2026-07-25) -- same
# systemd units, same Samba tuning, same firewall/discovery shape; the
# one real interface change the module boundary forces is that the list
# of shared trees can no longer be a relative-path import of a private
# file, so it is now `cfg.sharesmb`, supplied by the caller.
#
# SMB needs REAL auth (unlike NFS's AUTH_SYS) -- provide it via
# `smbpasswd` for each Unix user who should reach a share; this module
# only sets up the usershare machinery + auth backend, never seeds a
# password itself.
#
# Not paired with a `systemManagerModules` export (unlike the client-side
# providers): `services.samba`/`services.samba-wsdd`/`services.avahi` are
# full NixOS service modules with no system-manager equivalent -- this
# provider is nixosModules-only.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nixshare.server.cifs;

  # Set each SMB tree sharesmb=on, then turn OFF every descendant
  # dataset. sharesmb INHERITS down the tree, so a bare `set on` makes
  # EVERY child dataset its own top-level usershare. We want exactly
  # `cfg.sharesmb` as shares; their children still appear as SUBFOLDERS
  # inside them (smbd serves nested mounts transparently), so no
  # per-child share is needed or wanted. Tolerant of a not-yet-imported
  # pool (keeps the persisted property + skips its children).
  applyScript = ''
    for tree in ${lib.escapeShellArgs cfg.sharesmb}; do
      zfs set sharesmb=on "$tree" || { echo >&2 "smb-shares: $tree not ready, keeping persisted sharesmb"; continue; }
      zfs list -rH -o name "$tree" 2>/dev/null | tail -n +2 | while read -r child; do
        zfs set sharesmb=off "$child" || true
      done
    done
    zfs share -a || true
  '';
in
{
  options.services.nixshare.server.cifs = {
    enable = lib.mkEnableOption "Samba SMB file shares (ZFS sharesmb / usershares)";

    sharesmb = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Trees (pool/dataset) to expose as top-level SMB usershares
        (`zfs set sharesmb=on`), applied by the reconcile oneshot below.
        Access is gated by Samba auth (see this module's own header
        comment) plus `trustedInterfaces`, not by a per-client list here
        -- unlike the NFS provider's `sharenfs` matrix, SMB has no
        per-client ACL concept at the ZFS-property level.
      '';
    };

    netbiosName = lib.mkOption {
      type = lib.types.str;
      description = "NetBIOS name the box announces (<=15 chars, hyphen not underscore), e.g. reachable as \\\\<netbiosName>.";
    };

    workgroup = lib.mkOption {
      type = lib.types.str;
      default = "WORKGROUP";
      description = "SMB workgroup name.";
    };

    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "br0" "tailscale0" ];
      description = ''
        Interfaces the firewall opens SMB (tcp/445,139) + discovery (nmbd
        udp/137,138; WSD udp/3702 + tcp/5357; mDNS udp/5353) on.
        Interface-based (not nftables `extraInputRules`) so it works with
        the iptables firewall backend as well as nftables.
      '';
    };

    discoveryAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Pin `services.samba-wsdd`'s announced address explicitly. Left
        unset, wsdd binds ALL interfaces, which on a multi-bridge host
        (docker/k8s/etc alongside the LAN bridge) can make it answer from
        the wrong one -- a client would then see the server at the wrong
        IP. Set to the LAN-facing address if this host carries more than
        one.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.samba = {
      enable = true;
      # nmbd = NetBIOS name service: resolves \\<netbiosName> + legacy
      # browsing for older clients.
      nmbd.enable = true;
      settings.global = {
        "workgroup" = cfg.workgroup;
        "netbios name" = cfg.netbiosName;
        "server string" = lib.toLower cfg.netbiosName;
        "security" = "user";
        "map to guest" = "never";
        "server min protocol" = "SMB3";
        # usershares -- the mechanism ZFS `sharesmb` uses on Linux (`net usershare`).
        "usershare path" = "/var/lib/samba/usershares";
        "usershare max shares" = "200";
        "usershare allow guests" = "no";
        "usershare owner only" = "no";

        # macOS/xattr interop + correct metadata (vfs_fruit stack). Works
        # best against xattr=sa + dnodesize=auto ZFS datasets, where
        # alternate streams + extended attrs land efficiently in the SA.
        # catia remaps SMB-illegal chars (: * ? " < > |).
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:metadata" = "stream";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:nfs_aces" = "no";
        "fruit:zero_file_id" = "yes";
        "fruit:delete_empty_adfiles" = "yes";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:encoding" = "native";
        # Extended attributes + DOS attributes (backed by ZFS xattr=sa).
        "ea support" = "yes";
        "store dos attributes" = "yes";
        # This is a fileserver, not a print server -- drop the printing machinery.
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
        "disable spoolss" = "yes";
        # Setgid-tree rights model: new files/dirs must INHERIT the
        # parent's group semantics instead of Samba's default masks
        # (a create-mask default would strip group-w from a shared-group
        # contribution). 'inherit permissions' is the documented
        # setgid-tree mechanism: new dirs take the parent's mode incl.
        # setgid, new files take their rw bits from the parent; setuid is
        # never inherited (hard-blocked in smbd). Applies globally, so it
        # also covers every usershare (usershares can't carry per-share
        # params -- net usershare has only path/comment/acl/guest).
        "inherit permissions" = "yes";
        # Perf.
        "use sendfile" = "yes";
      };
    };

    # The usershare dir (net usershare writes here) + the passdb must
    # persist across an impermanent/tmpfs root -- bind/mount
    # /var/lib/samba onto durable storage in the CALLER's own host config
    # if applicable; smbd must start AFTER that bind or it reads an empty
    # passdb (`unitConfig.RequiresMountsFor` below is necessary but not
    # sufficient for that ordering -- the caller's own mount unit ordering
    # is what makes it correct end to end).
    systemd.tmpfiles.rules = [ "d /var/lib/samba/usershares 1770 root root -" ];
    systemd.services.samba-smbd.unitConfig.RequiresMountsFor = [ "/var/lib/samba" ];

    # Reconcile the caller's tree list onto the pool: set each SMB tree's
    # sharesmb, then share. Runs after smbd; idempotent + tolerant.
    systemd.services.smb-shares-apply = {
      description = "Apply the services.nixshare.server.cifs.sharesmb list onto the pool (self-describing SMB shares)";
      after = [ "samba-smbd.service" "zfs-mount.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      path = [ config.boot.zfs.package pkgs.samba pkgs.coreutils ];
      script = applyScript;
    };

    # WS-Discovery: modern Windows (10/11) dropped NetBIOS browsing, so
    # nmbd alone won't make the server appear in the network view -- wsdd
    # answers WS-Discovery so it shows up + is browsable.
    services.samba-wsdd = {
      enable = true;
      interface = lib.mkIf (cfg.discoveryAddress != null) cfg.discoveryAddress;
      workgroup = cfg.workgroup;
      hostname = cfg.netbiosName;
    };

    # mDNS/Avahi -- the third discovery leg. WSD (above) covers modern
    # Windows; nmbd covers legacy NetBIOS; without mDNS the server is
    # invisible to Avahi-based browsers (Linux file managers via
    # GVfs/KIO, Apple-style network browsing).
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      allowInterfaces = cfg.trustedInterfaces;
      publish = {
        enable = true;
        addresses = true;
        userServices = true;
        workstation = true;
      };
      extraServiceFiles.smb = ''
        <?xml version="1.0" standalone='no'?><!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">%h</name>
          <service>
            <type>_smb._tcp</type>
            <port>445</port>
          </service>
          <service>
            <type>_device-info._tcp</type>
            <port>0</port>
            <txt-record>model=RackMac</txt-record>
          </service>
        </service-group>
      '';
    };

    networking.firewall.interfaces = lib.genAttrs cfg.trustedInterfaces (_: {
      allowedTCPPorts = [ 445 139 5357 ];
      allowedUDPPorts = [ 137 138 3702 5353 ];
    });
  };
}
