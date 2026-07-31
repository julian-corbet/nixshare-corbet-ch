# modules/providers/nfs-server.nix
#
# The NFS server side: kernel nfsd (NFSv4-only), the idmapd Domain, firewall
# scoping, and a reconcile oneshot that applies a caller-supplied ZFS
# `sharenfs` matrix to the pool. The access matrix itself (which client
# reaches which export, at what squash) is supplied by the caller as
# `cfg.sharenfs` / `cfg.domain` (see README Quickstart) rather than baked
# in, so this module never imports a host-specific file.
#
# Not paired with a `systemManagerModules` export (unlike the client-side
# providers): `services.nfs.server`/`services.nfs.idmapd` are full NixOS
# service modules with no system-manager equivalent -- this provider is
# nixosModules-only.
{ config, lib, ... }:
let
  cfg = config.nixshare.server.nfs;

  # `tree` here is an ATTRSET KEY (the dataset name), not an option value --
  # unlike `val` (the sharenfs property string, already typed `str` and
  # already shell-escaped below), the key has no `lib.types` attached to
  # constrain it, and ZFS itself permits spaces and other shell
  # metacharacters in a dataset name. Both interpolations of `tree` in
  # `applyScript` used to be UNESCAPED (proven by eval: a declared dataset
  # name containing `;` or a backtick is root shell injection into this
  # oneshot's `script`). Fixed two ways, deliberately both -- defence in
  # depth, not either/or:
  #  - `safeZfsTreeName` rejects anything outside the character class a
  #    ZFS dataset name actually needs, at BUILD time (see the `assertions`
  #    entry in `config` below) -- a hostile name never gets this far;
  #  - `lib.escapeShellArg` on every interpolation of `tree`, not just
  #    `val`, is what keeps the generated script safe even if that
  #    assertion is ever bypassed by a future refactor or a caller path
  #    that skips module assertions.
  # Defined once in modules/zfs-names.nix and shared with providers/cifs-server.nix, which builds a
  # shell command around an operator-supplied dataset name for the same reason and therefore needs
  # the same answer. It was local to this file first, and the two providers immediately disagreed:
  # the identical hostile name was refused here and accepted there.
  inherit (import ../zfs-names.nix { inherit lib; }) safeZfsTreeName unsafeTreeNameMessage;

  # `zfs set sharenfs=<v> <tree>` per share -- tolerant (a tree whose pool
  # is not yet imported, e.g. a data pool before its own unlock, keeps its
  # already-persisted property; the pool carries it). The `|| echo ...`
  # fallback message passes `tree` to `echo` as ONE `escapeShellArg`-quoted
  # argument (rather than interpolating it into a bash double-quoted
  # string) precisely because a value emitted by `escapeShellArg` is only
  # safe as a whole shell token by itself -- embedding it inside another
  # quoted string would not carry the same guarantee.
  applyScript = lib.concatStringsSep "\n" (lib.mapAttrsToList (tree: val:
    "zfs set sharenfs=${lib.escapeShellArg val} ${lib.escapeShellArg tree} || echo >&2 ${lib.escapeShellArg "nfs-shares: ${tree} not ready, keeping persisted sharenfs"}"
  ) cfg.sharenfs) + "\nzfs share -a || true\n";
in
{
  options.nixshare.server.nfs = {
    enable = lib.mkEnableOption "NFSv4 export of a ZFS-`sharenfs`-carried tree matrix";

    domain = lib.mkOption {
      type = lib.types.str;
      description = ''
        NFSv4 idmapd Domain -- the shared name label ownership crosses the
        wire as (`user@domain`). MUST match this value on every client's
        own idmapd Domain, or ownership collapses to nobody:nobody.
      '';
    };

    sharenfs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = ''
        Tree (pool/dataset) -> the ZFS `sharenfs` property value to set on
        it, applied by the reconcile oneshot below. This is the access
        matrix in its already-rendered form -- see nixnet/nixshare's
        design note on definition-is-the-asset: build this attrset from
        your own client/tree model (rw addresses, squash, crossmnt, ...);
        this module only applies it and re-shares.

        Each key is a ZFS dataset name and MUST match
        `[A-Za-z0-9_.:/-]+` (enforced by an assertion in `config`, see
        `safeZfsTreeName`) -- it is inlined into a root shell script, and
        ZFS itself permits characters (including spaces) that would
        otherwise make a declared name into shell injection.
      '';
    };

    nproc = lib.mkOption {
      type = lib.types.int;
      default = 64;
      description = ''
        `services.nfs.server.nproc`. NixOS defaults to a fixed 8 kernel
        threads regardless of CPU count -- conservative for a modest box,
        undersized for a busy multi-client metadata-heavy fileserver (nfsd
        threads mostly idle-block on I/O rather than burn CPU, so
        oversizing cost is noise at a reasonable RAM/core budget while
        undersizing directly causes request-queuing tail latency). 64 is
        roughly 2/core on a 32-core box -- tune to your own hardware.
      '';
    };

    cpuWeight = lib.mkOption {
      type = lib.types.int;
      default = 200;
      description = ''
        cgroup v2 proportional-fair CPUWeight for nfs-server.service
        (default 100). Gives nfsd a scheduling edge over other CPU-heavy
        batch work during contention bursts -- NOT real-time scheduling
        (which would risk priority-inversion-class problems on a
        general-purpose kernel under load); this is safe and fully
        reversible.
      '';
    };

    ioWeight = lib.mkOption {
      type = lib.types.int;
      default = 200;
      description = "cgroup v2 IOWeight for nfs-server.service, same reasoning as cpuWeight.";
    };

    leaseTime = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      example = 45;
      description = ''
        NFSv4 lease time in seconds (`[nfsd] lease-time` in nfs.conf, which
        `rpc.nfsd` writes to `/proc/fs/nfsd/nfsv4leasetime` at startup).
        90 is the kernel default.

        This is the number that decides **how long a local write on this
        server stalls when a client holding a delegation on that file has
        vanished** — asleep, lid shut, off the network. The server must
        recall the delegation before the write may proceed; if the client
        does not answer, it waits out the full lease before revoking. So
        the lease time is the worst-case stall, and it is paid by processes
        running ON the server, not by the absent client.

        Lower it when clients are laptops rather than always-on hosts, and
        especially when `nixshare.nfsClient.delegationWatermark` is raised
        — a high watermark multiplies the number of files carrying that
        stall. Do not chase it to zero: the lease is also the window a
        client has to renew across a transient network blip, and a client
        that misses it loses ALL its state and must reclaim, which on a
        client holding tens of thousands of delegations is its own storm.

        Cannot be changed on a running server (`/proc/fs/nfsd/nfsv4leasetime`
        returns EBUSY while nfsd is up), so a change here takes effect on
        the next `nfs-server` restart, not at switch time.
      '';
    };

    graceTime = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      example = 45;
      description = ''
        NFSv4 grace period in seconds (`[nfsd] grace-time`) — how long
        after THIS server restarts clients may reclaim the state they held
        before. Keep it >= `leaseTime`: a client that was holding a lease
        needs at least a full lease period to notice the restart and
        reclaim, and a grace shorter than the lease silently drops state
        that was legitimately reclaimable. Same restart-to-apply caveat.
      '';
    };

    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "br0" "tailscale0" ];
      description = ''
        Interfaces the firewall opens NFS (tcp/2049) on. NFS must NEVER
        reach an untrusted network -- restricting to these interfaces is
        that guard. Interface-based (not nftables `extraInputRules`) so it
        works with the iptables firewall backend as well as nftables --
        `extraInputRules` is a silent no-op under iptables.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Reject a hostile dataset name at BUILD time -- see `safeZfsTreeName`
    # above for the full reasoning. This is the type-level/eval-time half
    # of the fix; `applyScript`'s `lib.escapeShellArg` on `tree` is the
    # other half, and both exist deliberately (defence in depth).
    assertions = lib.mapAttrsToList
      (tree: _: {
        assertion = safeZfsTreeName tree;
        message = ''
          nixshare.server.nfs.sharenfs."${tree}" is not a safe ZFS dataset
          name -- it must match [A-Za-z0-9_.:/-]+. ZFS itself permits other
          characters (including spaces), but this module inlines the name
          into a root shell script (nfs-shares-apply.service), so anything
          outside that class is refused here rather than risked
          downstream.
        '';
      })
      cfg.sharenfs;

    # Just the kernel nfsd -- NO /etc/exports. The shares live in the pool
    # as ZFS `sharenfs` properties (applied by nfs-shares-apply below); the
    # pool carries + serves them.
    services.nfs.server.enable = true;
    services.nfs.server.nproc = cfg.nproc;

    systemd.services.nfs-server.serviceConfig = {
      CPUWeight = cfg.cpuWeight;
      IOWeight = cfg.ioWeight;
    };

    # Reconcile the caller's matrix onto the pool: set each tree's
    # sharenfs property, then share. Runs after nfsd is up; idempotent +
    # tolerant (a not-yet-imported pool keeps its persisted property).
    systemd.services.nfs-shares-apply = {
      description = "Apply the nixshare.server.nfs.sharenfs matrix onto the pool (self-describing NFS shares)";
      after = [ "nfs-server.service" "zfs-mount.service" ];
      requires = [ "nfs-server.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      path = [ config.boot.zfs.package ];
      script = applyScript;
    };

    # NFSv4-only: a single well-known port (2049), no rpcbind / mountd /
    # statd / v2 / v3 surface.
    services.nfs.settings.nfsd = {
      vers2 = false;
      vers3 = false;
      vers4 = true;
      "vers4.0" = true;
      "vers4.1" = true;
      "vers4.2" = true;
      "lease-time" = cfg.leaseTime;
      "grace-time" = cfg.graceTime;
    };

    services.nfs.idmapd.settings.General.Domain = cfg.domain;

    networking.firewall.interfaces = lib.genAttrs cfg.trustedInterfaces (_: {
      allowedTCPPorts = [ 2049 ];
    });
  };
}
