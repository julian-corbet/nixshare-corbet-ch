# pkgs/nixshare-health.nix
#
# The SECOND failure mode, and the one the stuck-automount watchdog
# structurally cannot see.
#
# nixshare-watchdog watches for a mount attempt that never completes: a unit
# stuck in `activating`, cured by `umount -f -l`. This tool watches the exact
# opposite shape -- a mount that is fully `active`, whose files are readable,
# and which is nonetheless useless because every RPC to it takes seconds.
# The unit never leaves `active`, so the watchdog never fires; from systemd's
# point of view nothing is wrong at all.
#
# OBSERVED, on a real client (this is not a hypothetical):
#     one stat()          3263 ms      (server-side equivalent: 0.075 ms)
#     one touch()         1947 ms
#     200 small creates   382 seconds  (server-side, same dataset: 15 ms)
# while `ping` to the server was 3.4 ms, the NFS mount was `active`, files
# read back correctly, and `nfsstat -rc` showed retrans=1 out of 5,075,060
# calls. Nothing was retrying or failing -- every RPC simply stalled before
# it went out. The kernel's only complaint was
#     SUNRPC: reached max allowed number (1) did not add transport to server: <ip>
# The trigger was a metadata storm against the mount (a recursive chown over
# a git object store, ~10^5 failing per-file ops). The client's SUNRPC
# transport state never recovered on its own; the box ran degraded for hours.
#
# THE THING THIS ENCODES, which cost real time to learn: remounting the
# affected share DOES NOT FIX IT. NFS keeps ONE `nfs_client` per server,
# shared by every mount of that server (`/proc/fs/nfsfs/servers`, USE
# column). Unmounting one mountpoint leaves the refcount non-zero, so the
# remount reattaches to the SAME wedged client and nothing changes -- which
# is exactly what happened when it was tried by hand. The client is only
# destroyed once EVERY mount of that server is gone AND the fscache cookies
# holding it are released (stop cachefilesd, unload the `cachefiles`
# module). That is why `reset-client` acts on a whole PEER GROUP, not on one
# share, and why it touches cachefilesd at all.
#
# WHAT IT DELIBERATELY WILL NOT DO: cure a server that is simply down. A
# degraded probe and an unreachable server look identical from the
# mountpoint, and tearing down every mount of a dead server accomplishes
# nothing except thrash (and would fight the automount, which is trying to
# re-establish). So a reachability check gates every cure: if the server
# does not answer on its NFS port, this alerts and stops. Curing is only
# ever attempted when the server is provably fine and the CLIENT is the
# broken half -- the precise signature above.
#
# THE PROBE ITSELF HAD TWO BLIND SPOTS, both now fixed, both found the same
# way: a real client ran degraded for a long time with the monitor ticking
# the whole time and never once logging a bad probe.
#
#   1. A stat() on the mountpoint itself can be served entirely from the
#      attribute cache (`actimeo`) without ever reaching the network, and on
#      a host where something else keeps touching that same path -- a shell
#      prompt, an editor, a file-watcher -- the cache entry can be kept
#      perpetually warm, so the health probe's own stat() may go an entire
#      incident without ever being the one to force a fresh RPC. Fixed by
#      probing a name that is guaranteed not to exist: `lookupcache=positive`
#      (this provider's own default -- see modules/providers/nfs.nix) caches
#      only successful lookups, never negative ones, so a stat() against a
#      nonexistent child of the mountpoint always reaches the wire.
#
#   2. Independently, a stat()-only probe cannot see a wedge that is scoped
#      to READDIRPLUS specifically. Observed directly on a real client:
#      plain stat()/read()/write() on an already-established mount kept
#      working instantly for well over an hour while every operation that
#      issues READDIRPLUS -- a directory listing, `git status`, a file
#      manager's folder view -- hung indefinitely. No kernel log line on
#      either end the entire time; only a reboot cleared it. A probe built
#      from stat() alone is structurally incapable of detecting that class
#      no matter how it is tuned. Fixed by adding a second, independent
#      probe that reads a names-only directory listing from the mountpoint, so
#      a wedge confined to READDIRPLUS shows up even when every stat() is
#      fine. This deliberately does NOT `ls -la` the whole directory: on a
#      crossmnt ZFS tree that stats every child filesystem, multiplying a
#      harmless cold export-cache miss into seconds of work and making the
#      health check create the degradation it then tries to cure.
#
# Curing this second class is not guaranteed -- the one real incident needed
# a reboot even after manual intervention -- which is exactly why the
# escalation ladder below already ends in "manual intervention needed... a
# reboot clears client state unconditionally" rather than promising a fix.
# What detection buys is the alert firing in minutes instead of the person
# at the keyboard being the only sensor, for however long they tolerate it.
#
# HONEST LIMIT ON FIX 2: probe 2 reads directory names from the mountpoint
# itself, not a target constructed to defeat caching the way probe 1's
# nonexistent name does.
# `lookupcache` (probe 1's guarantee) governs LOOKUP caching only; directory
# CONTENT is governed separately by `actimeo`/`acdirmax`, so if something
# else lists that same mountpoint within the cache window, probe 2 can still
# read from a warm directory-page cache instead of the wire. Closing that
# fully means probing a target guaranteed fresh every tick -- e.g. a
# just-created, uniquely-named subdirectory, listed, then removed -- which
# was deliberately NOT done here: it turns a read-only probe into a
# periodic write+delete against every live share this monitors, a different
# risk profile that deserves its own sign-off rather than riding in on a
# detection fix. Left as a known, stated gap rather than a silent one.
#
# ALSO NFS-SPECIFIC: both probes' cache-defeat reasoning rests on this
# provider's `lookupcache=positive` default (modules/providers/nfs.nix).
# `probe_ms` itself runs unconditionally against CIFS shares too (core
# stays protocol-blind), but CIFS has no declared equivalent guarantee --
# `modules/providers/cifs.nix` only exposes `cache=strict|loose` -- so the
# "always reaches the wire" claim above is demonstrated for NFS only.
#
# WHY SHELL, NOT RUST: same carve-out as nixshare-watchdog (see its header).
# This is a systemd *oneshot* on a timer -- one pass, process exits every
# tick, no resident state. The little cross-tick state it does need
# (consecutive-failure counts, cure cooldown stamps) lives in files under
# the configured stateDir, not in the process. A genuinely resident daemon
# would warrant Rust; this is not that.
{ lib, writeShellApplication, bash, jq, systemd, util-linux, coreutils, gawk, gnugrep, kmod, iproute2 }:

writeShellApplication {
  name = "nixshare-health";
  # This is the executable's complete command closure.  Do not rely on the
  # ambient unit PATH: system-manager deliberately supplies a store-only PATH,
  # and recovery used to reach its teardown phase only to discover that `awk`
  # was absent.  `grep` is equally real even though its missing-command status
  # is hidden inside the optional kernel-marker pipeline.
  runtimeInputs = [ jq systemd util-linux coreutils gawk gnugrep kmod iproute2 ];
  text = ''
    # nixshare-health -- see pkgs/nixshare-health.nix and README.md
    # "How the health monitor works" for the full explanation.

    # --heal-only: restore any interrupted teardown and exit, probing nothing.
    # This is what the unit's ExecStopPost runs, so a tick killed by SIGKILL
    # (which no trap can catch) is repaired as soon as systemd reaps the
    # cgroup, instead of waiting up to a full poll interval for the next tick.
    heal_only=no
    [ "''${1:-}" = "--heal-only" ] && heal_only=yes

    config_file="''${NIXSHARE_HEALTH_CONFIG:-/etc/nixshare/health.json}"

    if [ ! -r "$config_file" ]; then
      echo "nixshare-health: cannot read config: $config_file (is nixshare.health.enable set?)" >&2
      exit 1
    fi

    if ! jq -e . >/dev/null 2>&1 < "$config_file"; then
      echo "nixshare-health: config is not valid JSON: $config_file" >&2
      exit 1
    fi

    degraded_ms=$(jq -r '.degradedLatencyMs' "$config_file")
    probe_timeout=$(jq -r '.probeTimeoutSec' "$config_file")
    needed_fails=$(jq -r '.consecutiveFailures' "$config_file")
    cooldown=$(jq -r '.cooldownSec' "$config_file")
    recovery=$(jq -r '.recovery' "$config_file")
    reset_teardown_timeout=$(jq -r '.resetTeardownTimeoutSec' "$config_file")
    state_dir=$(jq -r '.stateDir' "$config_file")
    alert_command=$(jq -r '.alertCommand // empty' "$config_file")

    mkdir -p "$state_dir"

    # Fire the configured alert, if any. Never fatal: an alert channel being
    # down must not stop a recovery that is otherwise working.
    #
    # alert_command is a Nix-eval-time-trusted, already-shell-escaped command
    # PREFIX (nixpush's own `mkSendCommand` helper -- see modules/core.nix's
    # `watchdog.alertCommand` option -- is exactly what most deployments bake
    # it from, and its own doc comment says so: "append your own quoted
    # message"). The previous version here instead handed the message to a
    # `sh -c "$alert_command" "nixshare-health" "$1"` subshell as a
    # positional argument the command string never referenced, so it was
    # silently dropped on every real alert -- nixpush's `send` errored
    # "MESSAGE is required" and the push never went out, even though
    # detection itself was working. Fixed to match nixshare-watchdog.nix's
    # own send_alert, the sibling implementation of this exact contract:
    # append the runtime message, `%q`-quoted, and eval the whole thing.
    notify() {
      local message="$1"
      echo "nixshare-health: $message"
      if [ -n "$alert_command" ]; then
        # shellcheck disable=SC2086
        if ! eval "$alert_command $(printf '%q' "$message")"; then
          echo "nixshare-health: alert command failed (continuing)" >&2
        fi
      fi
    }

    # systemd's own escaping, never a hand-rolled reimplementation -- same
    # stance as nixshare-watchdog.
    unit_for() { systemd-escape -p --suffix=mount "$1"; }
    automount_for() { systemd-escape -p --suffix=automount "$1"; }

    # Is the server answering on the NFS port at all? This is the gate that
    # separates "client is wedged" (curable) from "server is down or the
    # network is gone" (not curable, and thrashing would make it worse).
    # bash's own /dev/tcp -- no extra tool, no ICMP dependency (ICMP can be
    # filtered while 2049 is fine, and vice versa). The absolute store path
    # is load-bearing: system-manager units receive a store-only PATH, and a
    # bare `bash` here once made every live server look unreachable while
    # stderr suppression hid the missing-command error. This gate decides
    # whether client recovery runs at all, so it must not depend on ambient
    # PATH.
    server_reachable() {
      local peer="$1" port="''${2:-2049}"
      timeout 5 ${lib.getExe bash} -c "exec 3<>/dev/tcp/$peer/$port" 2>/dev/null
    }

    # Milliseconds for TWO probes against the mountpoint -- see "THE PROBE
    # ITSELF HAD TWO BLIND SPOTS" above for why it is two, not one. Prints
    # the combined elapsed time; returns non-zero only if either probe was
    # actually killed by its own timeout budget (a timeout is the most
    # degraded reading there is, so it counts as the full probe budget
    # rather than as "no data"). A clean, fast failure -- the negative
    # stat's expected ENOENT -- is not a timeout and must not be treated
    # as one, or every tick on a perfectly healthy share would read as
    # maximally degraded.
    probe_ms() {
      local mp="$1" start end rc1=0 rc2=0
      start=$(date +%s%N)
      # -k: follow SIGTERM with SIGKILL. HONEST LIMIT, stated rather than
      # papered over: neither signal can end a syscall parked in an
      # UNINTERRUPTIBLE (D) kernel wait -- SIGKILL is queued but not delivered
      # until the task returns to userspace -- so against a truly hung mount
      # `timeout` itself does not return and this tick stalls. That is a
      # kernel-level constraint, not a scripting one. Backgrounding the probe
      # and abandoning it would be WORSE, not better: an abandoned syscall
      # holds a reference on the wedged mount, and those references are
      # exactly what keeps the nfs_client refcount above zero -- it would
      # sabotage the one cure that works. The flock below bounds the damage
      # to a single stuck process instead of one per tick.
      #
      # Probe 1: stat() a name that cannot exist. Never cache-served (see
      # above) -- this is what proves the transport itself is alive, not
      # just that a warm attribute-cache entry hasn't expired yet. The `||`
      # is load-bearing under `set -e`: this stat is EXPECTED to fail
      # (ENOENT) on every healthy tick, and that must not abort the script.
      timeout -k 5 "$probe_timeout" stat -c %i "$mp/.nixshare-health-probe" >/dev/null 2>&1 || rc1=$?
      # Probe 2: read directory names without metadata. Deliberately NOT
      # redundant with probe 1 -- this catches a wedge confined to
      # READDIRPLUS while plain stat() keeps working. `ls -U1` does not
      # sort and, with metadata/color disabled, does not stat the children.
      # The old `ls -la` did: on ZFS crossmnt trees it crossed every child
      # filesystem, multiplying one ordinary cold export-cache miss per
      # child into a false ten-second outage and a needless reset.
      timeout -k 5 "$probe_timeout" ls -U1 --color=never "$mp" >/dev/null 2>&1 || rc2=$?
      end=$(date +%s%N)
      echo $(( (end - start) / 1000000 ))
      # rc1 and rc2 are NOT interchangeable, because a healthy tick is
      # expected to end each sub-probe differently. Probe 1's stat is
      # expected to FAIL (ENOENT) every time -- that is the whole point --
      # so only a timeout counts against it (124 = timeout's own TERM kill,
      # 137 = the -k KILL follow-up). Probe 2's names-only scan is expected to
      # SUCCEED every time -- reading an established mount is not supposed to
      # fail -- so ANY nonzero from it (ESTALE, EIO, a permission problem,
      # not just a timeout) is a real signal and must count as degraded.
      # Collapsing these into one shared check would silently reclassify a
      # fast, genuine directory-scan failure as a healthy tick.
      if [ "$rc1" -eq 124 ] || [ "$rc1" -eq 137 ] || [ "$rc2" -ne 0 ]; then
        return 1
      fi
      return 0
    }

    # Read a numeric counter from a state file, tolerating anything that is
    # not a clean integer. Load-bearing, not defensive noise: under `set -u`
    # bash's arithmetic context treats a non-numeric bare word as a VARIABLE
    # NAME, so `fails=$(( fails + 1 ))` against a corrupt state file is an
    # "unbound variable" HARD ABORT, not a tolerable non-zero exit. That abort
    # lands inside the per-peer loop BEFORE the file is rewritten, so the
    # corruption never heals and every peer ordered after the bad one is
    # silently never probed again -- a permanent monitoring blackout from one
    # truncated write (OOM kill, power loss, full disk). Verified: a state file
    # containing "garbage" aborts the script with exit 1.
    read_counter() {
      local f="$1" raw=""
      [ -f "$f" ] && raw=$(cat "$f" 2>/dev/null || true)
      case "$raw" in
        ""|*[!0-9]*) echo 0 ;;
        *) echo "$raw" ;;
      esac
    }

    ${builtins.readFile ./nixshare-health-reset.sh}

    # Every mount of a given server shares ONE nfs_client, so `reset-client`
    # can only destroy it if it tears down ALL of them. This lists mounts of
    # `$1` that are live on the box but NOT in the peer group being cured --
    # each one keeps the refcount above zero and makes the cure a silent
    # no-op. nixshare must not unmount what it does not own, so it reports
    # them instead: without this the operator sees a recovery that "ran fine"
    # and changed nothing, with no clue why. Matches on the device prefix as
    # written in /proc/mounts, so a peer named differently there (an IP vs a
    # name) will not be spotted -- stated in README rather than guessed at.
    # A mount is COVERED if it is a declared mountpoint, or lives anywhere
    # BENEATH one. That second clause is not a convenience -- without it this
    # check is wrong by two orders of magnitude on any real server.
    #
    # NFSv4 exports carrying `crossmnt` (which is what ZFS per-dataset sharing
    # produces, and it is the norm, not an edge case) make the kernel
    # synthesize a NEW mount the first time any process traverses into a
    # directory that is a separate dataset server-side. Those submounts have
    # no systemd unit and no FragmentPath -- nothing in any config declares
    # them, and nothing can: they appear on access, and the set only ever
    # grows as more of the tree is touched. One observed client went from 7 to
    # 53 to 124 live mounts of a single server in a few hours, against 9
    # declared shares and ~200 crossmnt exports available to it.
    #
    # Comparing raw mountpoints against the declared list would therefore
    # report a hundred-plus "undeclared" mounts and refuse recovery forever,
    # on a host whose coverage is in fact complete. A submount of a declared
    # share is already owned: tearing that share's subtree down removes it,
    # and it returns by itself on the next traversal -- no declaration needed.
    # Only a mount of this server living OUTSIDE every declared share is a
    # genuine coverage gap.
    unmanaged_mounts_for() {
      local peer="$1"; shift
      local declared=("$@") mp d covered
      while read -r dev mp _; do
        case "$dev" in
          "$peer":*) ;;
          *) continue ;;
        esac
        covered=no
        for d in "''${declared[@]}"; do
          if [ "$mp" = "$d" ] || case "$mp" in "$d"/*) true ;; *) false ;; esac; then
            covered=yes
            break
          fi
        done
        [ "$covered" = no ] && echo "$mp"
      done < /proc/mounts
    }

    # Every live mount at or beneath a declared mountpoint, DEEPEST FIRST.
    # The teardown must unmount the whole subtree: each crossmnt submount is
    # an independent mount of the same server and holds its own reference on
    # the shared nfs_client, so unmounting only the declared parent leaves the
    # refcount above zero and the reset silently fails -- the exact failure the
    # peer-grouping exists to avoid, reintroduced one level down.
    subtree_mounts_of() {
      local root="$1" mp
      while read -r _ mp _; do
        if [ "$mp" = "$root" ] || case "$mp" in "$root"/*) true ;; *) false ;; esac; then
          echo "$mp"
        fi
      done < /proc/mounts | awk '{ print gsub(/\//,"/"), $0 }' | sort -rn | cut -d" " -f2-
    }

    # ------------------------------------------------------------------
    # THE RESTORE GUARANTEE.
    #
    # Between "stop the peer's mounts" and "start them again" there is a
    # window in which this host has NO mounts of that server AND no
    # automounts to re-trigger them (the reset stops those too, deliberately
    # -- an automount re-establishing mid-teardown would recreate the very
    # nfs_client reference the reset exists to drop). Dying in that window
    # leaves the box with its network storage simply GONE, which is far
    # worse than the degradation being cured.
    #
    # That is not a theoretical risk: systemd's DefaultTimeoutStartSec is
    # 15s on a stock host, the teardown runs against a WEDGED client where
    # every `systemctl stop` is itself slow, and the real incident's manual
    # teardown took well over a minute. Without a bound raised at the unit
    # level (modules/core.nix sets TimeoutStartSec from recoveryTimeoutSec)
    # SIGTERM lands mid-window essentially every time.
    #
    # So: record what has been torn down, and restore it from an EXIT/TERM/INT
    # trap. Idempotent -- `systemctl start` on an already-started unit is a
    # no-op, so running this twice (trap plus the normal path) is harmless.
    # SIGKILL cannot be trapped; modules/core.nix adds an ExecStopPost
    # backstop for that case.
    # ------------------------------------------------------------------
    teardown_mps=()
    teardown_cachefilesd=no
    teardown_file=""

    restore_torn_down() {
      [ "''${#teardown_mps[@]}" -gt 0 ] || return 0
      echo "nixshare-health: restoring ''${#teardown_mps[@]} mount(s) torn down by recovery"
      local mp
      for mp in "''${teardown_mps[@]}"; do
        systemctl start "$(unit_for "$mp")" 2>/dev/null || true
      done
      for mp in "''${teardown_mps[@]}"; do
        systemctl start "$(automount_for "$mp")" 2>/dev/null || true
      done
      if [ "$teardown_cachefilesd" = yes ]; then
        systemctl start cachefilesd 2>/dev/null || true
      fi
      teardown_mps=()
      teardown_cachefilesd=no
      [ -n "''${teardown_file:-}" ] && rm -f "$teardown_file"
      teardown_file=""
      return 0
    }

    trap restore_torn_down EXIT INT TERM

    # SIGKILL cannot be trapped, and neither can an OOM kill or a crash. So
    # the armed list is also written to disk before the first stop and removed
    # after a successful restore: a leftover file means a previous run died
    # mid-teardown, and THIS run restores those mounts before doing anything
    # else. Self-healing on the next tick, with no systemd machinery needed.
    # (A reboot needs no handling -- stateDir is tmpfs and the automounts come
    # back on their own.)
    recover_orphaned_teardowns() {
      local f mp
      for f in "$state_dir"/teardown.*; do
        [ -e "$f" ] || continue
        echo "nixshare-health: found an interrupted teardown ($f) -- restoring its mounts first" >&2
        while read -r mp; do
          case "$mp" in
            "") continue ;;
            "CACHEFILESD") systemctl start cachefilesd 2>/dev/null || true ;;
            *) systemctl start "$(unit_for "$mp")" 2>/dev/null || true
               systemctl start "$(automount_for "$mp")" 2>/dev/null || true ;;
          esac
        done < "$f"
        rm -f "$f"
      done
    }

    # ONE instance at a time. systemd already merges overlapping timer jobs,
    # but a hand-run `nixshare-health` during a timer tick has no such
    # protection -- and two concurrent recoveries tearing down the same peer
    # is exactly the interleaving that strands mounts. Non-blocking: a second
    # caller reports and leaves rather than queueing behind a stuck probe.
    exec 9>"$state_dir/health.lock"
    if ! flock -n 9; then
      echo "nixshare-health: another instance holds the lock -- skipping this run"
      exit 0
    fi

    recover_orphaned_teardowns

    if [ "$heal_only" = yes ]; then
      echo "nixshare-health: --heal-only, nothing further to do"
      exit 0
    fi

    now=$(date +%s)
    peer_count=$(jq -r '.peers | length' "$config_file")
    [ "$peer_count" -gt 0 ] || exit 0

    for pi in $(seq 0 $(( peer_count - 1 ))); do
      peer=$(jq -r ".peers[$pi].peer" "$config_file")
      protocol=$(jq -r ".peers[$pi].protocol" "$config_file")
      port=$(jq -r ".peers[$pi].port" "$config_file")
      share_count=$(jq -r ".peers[$pi].shares | length" "$config_file")

      slug=$(printf '%s' "$peer-$protocol" | tr -c 'A-Za-z0-9_.-' '_')
      fail_file="$state_dir/health.$slug.fails"
      cure_file="$state_dir/health.$slug.lastcure"

      bad=0
      checked=0
      worst=0
      detail=""

      for si in $(seq 0 $(( share_count - 1 )) ); do
        mp=$(jq -r ".peers[$pi].shares[$si].mountpoint" "$config_file")
        unit=$(unit_for "$mp")

        # Only ESTABLISHED mounts are ours. Anything still activating (or
        # not mounted at all) belongs to nixshare-watchdog; probing it here
        # would both duplicate that job and, worse, block this tick behind
        # the very establish attempt the watchdog is about to cure.
        state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo unknown)
        [ "$state" = "active" ] || continue

        checked=$(( checked + 1 ))
        ms=$(probe_ms "$mp") || ms=$(( probe_timeout * 1000 ))
        [ "$ms" -gt "$worst" ] && worst=$ms
        if [ "$ms" -gt "$degraded_ms" ]; then
          bad=$(( bad + 1 ))
          detail="$detail $mp=''${ms}ms"
        fi
      done

      # Nothing mounted for this peer right now: not our problem, and the
      # failure counter must not persist across an idle-teardown.
      if [ "$checked" -eq 0 ]; then
        rm -f "$fail_file"
        continue
      fi

      if [ "$bad" -eq 0 ]; then
        if [ -f "$fail_file" ]; then
          echo "nixshare-health: $peer recovered (worst probe ''${worst}ms)"
          rm -f "$fail_file"
        fi
        continue
      fi

      # Hysteresis. A single slow tick is normal under real load -- a big
      # copy, a cold cache, a scrub on the server. Only a SUSTAINED stall is
      # the signature this tool acts on.
      fails=$(read_counter "$fail_file")
      fails=$(( fails + 1 ))
      echo "$fails" > "$fail_file"
      echo "nixshare-health: $peer degraded ($bad/$checked probes over ''${degraded_ms}ms:$detail) [$fails/$needed_fails]"
      [ "$fails" -ge "$needed_fails" ] || continue

      # THE GATE. Server down != client wedged, and only the latter is
      # curable from here.
      if ! server_reachable "$peer" "$port"; then
        notify "$peer unreachable on port $port -- degraded mounts are a SERVER/NETWORK outage, not a client wedge. Not attempting recovery."
        continue
      fi

      last_cure=$(read_counter "$cure_file")
      if [ $(( now - last_cure )) -lt "$cooldown" ]; then
        echo "nixshare-health: $peer still degraded but within cooldown ($(( now - last_cure ))s < ''${cooldown}s) -- not re-curing"
        continue
      fi

      # Useful corroboration for the human reading the alert. Not a gate:
      # absence of this line does not mean the client is healthy.
      marker=""
      if dmesg 2>/dev/null | tail -200 | grep -q "did not add transport to server"; then
        marker=" (kernel: SUNRPC 'did not add transport' present)"
      fi

      if [ "$recovery" = "alert" ]; then
        notify "$peer degraded: $bad/$checked probes over ''${degraded_ms}ms, worst ''${worst}ms$marker. recovery=alert, taking no action."
        # Stamping the cooldown on the alert-only path is deliberate: it makes
        # cooldownSec the notification rate-limit too, so a peer that stays
        # degraded produces one alert per cooldown window rather than one per
        # tick. Without this, recovery="alert" is an alert-spam generator.
        echo "$now" > "$cure_file"
        continue
      fi

      notify "$peer degraded (worst ''${worst}ms$marker) -- attempting recovery=$recovery"
      echo "$now" > "$cure_file"

      # --- Step 1: remount just this peer's shares -----------------------
      # Cheapest thing that could work, and it IS enough when the stall is
      # in a single mount's own state rather than the shared client.
      mapfile -t mps < <(jq -r ".peers[$pi].shares[].mountpoint" "$config_file")
      for mp in "''${mps[@]}"; do
        systemctl restart "$(unit_for "$mp")" 2>/dev/null || true
      done

      sleep 2
      recheck=0
      for mp in "''${mps[@]}"; do
        ms=$(probe_ms "$mp") || ms=$(( probe_timeout * 1000 ))
        [ "$ms" -gt "$degraded_ms" ] && recheck=$(( recheck + 1 ))
      done

      if [ "$recheck" -eq 0 ]; then
        notify "$peer recovered after remount."
        rm -f "$fail_file"
        continue
      fi

      if [ "$recovery" != "reset-client" ] || [ "$protocol" != "nfs" ]; then
        notify "$peer STILL degraded after remount, and recovery=$recovery (protocol=$protocol) permits nothing further. Manual intervention needed."
        continue
      fi

      # --- Step 2: destroy and rebuild the whole nfs_client --------------
      # The step that actually works, and the reason this tool groups by
      # peer. Every mount of this server must go, AND the fscache cookies
      # pinning the client must be released, or the refcount never reaches
      # zero and the rebuilt mounts reattach to the same wedged client.
      # REFUSE, do not merely warn. Every mount of this server shares one
      # nfs_client, so a mount nixshare does not know about holds its refcount
      # above zero and the reset cannot destroy it. Proceeding anyway would
      # stop every one of this peer's mounts, stop cachefilesd and unload the
      # cachefiles module -- real, host-wide disruption -- to achieve provably
      # nothing. Losing a cure that could never have worked costs the operator
      # one alert; performing it costs them their mounts for the duration and
      # fixes nothing. The cooldown is still stamped so this refusal does not
      # re-fire every tick.
      mapfile -t strays < <(unmanaged_mounts_for "$peer" "''${mps[@]}")
      if [ "''${#strays[@]}" -gt 0 ]; then
        notify "$peer -- REFUSING reset-client: ''${#strays[@]} mount(s) of this server are not declared to nixshare (''${strays[*]}). They share the same nfs_client and would hold its refcount above zero, so the reset would tear everything down and still not take effect. Fix: declare them as shares of peer '$peer' (no other change needed), or unmount them. Not touching anything."
        continue
      fi

      # Snapshot the exact NFS clients backing this peer's declared mount
      # roots while those mounts still exist. The later teardown proof
      # joins mountinfo device IDs to nfsfs/volumes, so it does not depend on
      # the configured peer name and the kernel hostname spelling agreeing.
      if ! nixshare_capture_target_nfs_clients "''${mps[@]}"; then
        notify "$peer -- REFUSING reset-client [observation-unavailable]: could not identify the target NFS client through mountinfo and nfsfs/volumes. Not touching anything."
        continue
      fi

      echo "nixshare-health: $peer -- tearing down the shared nfs_client (all ''${#mps[@]} mount(s) + fscache)"

      # Arm the restore guarantee BEFORE the first stop, so any death from
      # here on re-establishes these mounts on the way out.
      teardown_mps=("''${mps[@]}")
      teardown_file="$state_dir/teardown.$slug"
      printf '%s\n' "''${mps[@]}" > "$teardown_file"

      for mp in "''${mps[@]}"; do
        systemctl stop "$(automount_for "$mp")" 2>/dev/null || true
      done
      for mp in "''${mps[@]}"; do
        systemctl stop "$(unit_for "$mp")" 2>/dev/null || true
        # Deepest first: a parent cannot be unmounted while its crossmnt
        # children are still mounted, and each child holds its own reference
        # on the shared client. The declared mountpoint itself is included by
        # subtree_mounts_of, so it is unmounted last, after its subtree.
        while read -r sub; do
          [ -n "$sub" ] || continue
          umount -f -l "$sub" 2>/dev/null || true
        done < <(subtree_mounts_of "$mp")
      done

      # teardown_cachefilesd is the trap's record, so there is exactly ONE
      # piece of state saying "this must be started again" -- the normal and
      # the interrupted paths read the same flag.
      if systemctl is-active --quiet cachefilesd 2>/dev/null; then
        teardown_cachefilesd=yes
        echo "CACHEFILESD" >> "$teardown_file"
        systemctl stop cachefilesd 2>/dev/null || true
      fi
      # Releases the fscache cookies that keep the nfs_client refcount above
      # zero. Harmless no-op when the module is absent or not in use.
      modprobe -r cachefiles 2>/dev/null || true

      # A successful umount command only proves namespace detachment. Open
      # references can keep the old mount, its nfs_client, volumes and RPC
      # transports alive after `umount -f -l` returns. Remounting at that
      # point simply reconnects to the old client and makes the reset a
      # no-op. Prove the captured kernel identities and their live TCP:2049
      # sockets are gone before restore; the wait is explicitly bounded.
      reset_incomplete=""
      if ! nixshare_wait_for_nfs_teardown "$reset_teardown_timeout"; then
        reset_incomplete="$nfs_teardown_state"
      fi

      # Same code path the trap uses, so the normal and the interrupted case
      # can never drift apart. Clears the armed state on success.
      restore_torn_down

      if [ -n "$reset_incomplete" ]; then
        notify "$peer RESET INCOMPLETE [$reset_incomplete] after waiting ''${reset_teardown_timeout}s for kernel teardown. Mounts were restored, but the old client was not proven destroyed; this run is not a complete nfs_client reset. Open references or retained kernel transports require manual intervention."
        continue
      fi

      sleep 2
      final=0
      fworst=0
      for mp in "''${mps[@]}"; do
        ms=$(probe_ms "$mp") || ms=$(( probe_timeout * 1000 ))
        [ "$ms" -gt "$fworst" ] && fworst=$ms
        [ "$ms" -gt "$degraded_ms" ] && final=$(( final + 1 ))
      done

      if [ "$final" -eq 0 ]; then
        notify "$peer RECOVERED after nfs_client reset (worst probe now ''${fworst}ms, was ''${worst}ms)."
        rm -f "$fail_file"
      else
        # Undeclared mounts cannot be the explanation here: their presence is
        # now a hard refusal above, so reaching this point means coverage was
        # complete and the client still did not come back healthy.
        notify "$peer STILL DEGRADED after a complete nfs_client reset ($final mount(s), worst ''${fworst}ms). Coverage was complete, so this is not an undeclared-mount problem. Manual intervention needed -- a reboot clears client state unconditionally."
      fi
    done
  '';

  meta = with lib; {
    description = "Detect and cure a degraded-but-mounted NFS client (a wedged SUNRPC transport, or a hang confined to READDIRPLUS), which the stuck-automount watchdog cannot see";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
