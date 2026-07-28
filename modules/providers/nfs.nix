# modules/providers/nfs.nix
#
# The NFS backend: turns every `nixshare.shares.<name>` with
# `protocol = "nfs"` into a real `systemd.mounts` + `systemd.automounts`
# pair. Never imported by core.nix itself -- opt in alongside it, same
# shape as nixnet's provider modules. Shared verbatim between
# nixosModules.nfs-provider and systemManagerModules.nfs-provider.
{ lib, config, ... }:

with lib;

let
  cfg = config.nixshare;

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
      # softreval: keep serving PATHS and ATTRIBUTES from cache once revalidation
      # has timed out, instead of failing. It changes nothing while the server is
      # reachable -- revalidation simply succeeds -- so it is not a throughput
      # knob; it only alters behaviour in the degraded case, which is exactly the
      # case a laptop-class client spends its worst minutes in.
      #
      # WHY IT MATTERS WITH `soft`: on a plain soft mount an outage makes even a
      # stat() on an ALREADY-CACHED path fail once the retrans budget is spent
      # (here ~35 s: timeo is deciseconds and the RPC timeout doubles per
      # retransmission, 5 + 10 + 20). A desktop session stats every mountpoint at
      # login, so the session stalls on paths whose attributes the client already
      # holds. With softreval those resolve instantly from cache, while anything
      # that genuinely needs the server still times out and errors after retrans
      # -- nfs(5) states that combination explicitly. The bounded-failure property
      # `soft` exists to provide is therefore preserved, not traded away.
      #
      # It also helps the teardown path: nfs(5) calls out "trying to unmount a
      # filesystem tree from a server that is permanently down" as a motivating
      # case -- the same stuck-unmount class that LazyUnmount and this module's
      # watchdog exist to survive.
      useSoftreval = (opt s "softreval" "false") == "true";
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
      ] ++ optional useFsc "fsc"
        ++ optional useSoftreval "softreval";
    in
    concatStringsSep "," (base ++ s.extraOptions);

in
{
  options.nixshare.nfsClient.delegationWatermark = mkOption {
    type = types.nullOr types.ints.positive;
    default = null;
    example = 50000;
    description = ''
      `nfsv4.delegation_watermark` — the cap on how many NFSv4 delegations
      this HOST's NFS client will hold before it starts handing them back.
      Client-global on purpose: it is a kernel module parameter, one value
      for the whole machine, so it deliberately does not live under
      `shares.<name>` the way `cacheSettings` does. `null` leaves the
      kernel default (5000) alone.

      Raise it when the client legitimately works over more open files
      than the default allows. Above the watermark the client continuously
      returns every delegation that has no active reference — and during a
      tree-walk every file goes unreferenced the moment it is closed, so
      each new `OPEN`'s delegation is reaped immediately and every file
      costs `OPEN` + `DELEGRETURN` instead of `OPEN` alone. Re-reads never
      get cheaper, because the delegation is always already gone.

      Measured on a host holding ~40k delegations against the 5000 default,
      reading 250 previously-untouched files twice:

        watermark 5000   pass 1: 250 OPEN + 250 DELEGRETURN
                         pass 2: 250 OPEN + 250 DELEGRETURN   (no reuse)
        watermark 50000  pass 1: 250 OPEN +   0 DELEGRETURN
                         pass 2:   0 OPEN +   0 DELEGRETURN   (fully local)

      The cost is server-side state: the server tracks every delegation it
      has handed out, and every LOCAL write on the server to a delegated
      file forces a `CB_RECALL` round-trip back to this client before the
      write proceeds. On a link where that round-trip is slow (a laptop on
      WiFi), a high watermark converts "client caches well" into "server
      writes stall". Size it to the working set you actually want cached,
      not to infinity.
    '';
  };

  config = mkIf (cfg.enable && nfsShares != { }) {
    nixshare.providers.nfs.enable = true;

    # Two mechanisms on purpose, because neither alone is sufficient:
    # modprobe.d applies only when the module is LOADED (so it covers every
    # future boot), and the sysfs write applies to the module that is
    # ALREADY loaded (so the setting takes effect on switch, without
    # demanding a reboot to become true). The parameter is 0644 in sysfs,
    # so the running value is writable.
    environment.etc."modprobe.d/nixshare-nfs.conf" =
      mkIf (cfg.nfsClient.delegationWatermark != null) {
        text = ''
          # Managed by nixshare (modules/providers/nfs.nix).
          options nfsv4 delegation_watermark=${toString cfg.nfsClient.delegationWatermark}
        '';
      };

    systemd.services.nixshare-nfs-client-tunables =
      mkIf (cfg.nfsClient.delegationWatermark != null) {
        description = "Apply nixshare NFS client tunables to the already-loaded nfsv4 module";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          p=/sys/module/nfsv4/parameters/delegation_watermark
          # Absent means nfsv4 is not loaded yet; modprobe.d above will
          # supply the value at load time, so this is a no-op, not a failure.
          if [ -w "$p" ]; then
            echo ${toString cfg.nfsClient.delegationWatermark} > "$p"
            echo "nixshare: delegation_watermark = $(cat $p)"
          else
            echo "nixshare: nfsv4 not loaded; modprobe.d will apply the watermark at load"
          fi
        '';
      };

    # ── `fsc` IS genuinely per-share, and it can differ between a share and
    # its own SUBTREE -- which is what makes a granular cache policy
    # possible at all. Verified by remounting shares individually and
    # reading the live flag out of /proc/mounts.
    #
    # ⚠ WITH ONE HARD RULE, MEASURED AND DETERMINISTIC: **a mount inherits
    # `fsc` from an already-mounted ANCESTOR, overriding its own option.**
    # With the parent tree mounted WITH fsc, three different child datasets
    # each asked for no fsc and each came up cached -- 9 of 9 attempts, no
    # variation. Unmount that parent and the same mounts honour themselves
    # exactly: 4 of 4 came up uncached, and a sibling asking FOR fsc got
    # it. The child's request is simply discarded while a cached ancestor
    # is live, and nothing in the unit file shows it -- only /proc/mounts
    # and /proc/fs/nfsfs/volumes do.
    #
    # CONSEQUENCE FOR CALLERS, enforced by the assertion below: to scope
    # caching to part of a tree, the ENCLOSING share must declare
    # `fsc = "false"` and the caching must go on the leaves. A cached
    # parent silently makes every declared child cached too, and the
    # config then lies about what it does.
    #
    # (Recorded honestly rather than folded into a tidy theory: on the same
    # host, four top-level shares that are NOT descendants of any cached
    # share also came up carrying fsc after boot, when seven mounts to one
    # server established simultaneously at login. Remounting any of them
    # alone cleared it. Ancestry cannot explain that one -- the shared
    # NFSv4 pseudo-root is the obvious suspect but was not proven. If you
    # see unexplained fsc on a share, remount it alone and re-check.)
    assertions =
      let
        fscOf = s: (opt s "fsc" "false") == "true";
        under = a: b: a.peer == b.peer
          && a.mountpoint != b.mountpoint
          && hasPrefix "${b.mountpoint}/" a.mountpoint;
        cachedAncestors = s: filter (o: fscOf o && under s o) (attrValues nfsShares);
      in
      mapAttrsToList
        (name: s: {
          assertion = cachedAncestors s == [ ];
          message = ''
            nixshare.shares.${name} (${s.mountpoint}) is enclosed by a share
            that sets cacheSettings.fsc = "true"
            (${concatStringsSep ", " (map (o: o.mountpoint) (cachedAncestors s))}),
            so its OWN fsc setting will be discarded at mount time.

            A mount inherits fsc from an already-mounted ancestor. Measured
            deterministically: with a cached parent live, 9 of 9 child mounts
            asking for no fsc came up cached anyway; with the parent
            unmounted, 4 of 4 honoured themselves. Nothing in the generated
            unit file reveals this -- only /proc/mounts does.

            Fix: set cacheSettings.fsc = "false" (or leave it unset) on the
            enclosing share and declare caching on the leaves that should
            actually have it.
          '';
        })
        nfsShares;

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
