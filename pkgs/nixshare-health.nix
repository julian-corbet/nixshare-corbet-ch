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
# WHY SHELL, NOT RUST: same carve-out as nixshare-watchdog (see its header).
# This is a systemd *oneshot* on a timer -- one pass, process exits every
# tick, no resident state. The little cross-tick state it does need
# (consecutive-failure counts, cure cooldown stamps) lives in files under
# the configured stateDir, not in the process. A genuinely resident daemon
# would warrant Rust; this is not that.
{ lib, writeShellApplication, jq, systemd, util-linux, coreutils, kmod, iproute2 }:

writeShellApplication {
  name = "nixshare-health";
  runtimeInputs = [ jq systemd util-linux coreutils kmod iproute2 ];
  text = ''
    # nixshare-health -- see pkgs/nixshare-health.nix and README.md
    # "How the health monitor works" for the full explanation.

    config_file="''${NIXSHARE_HEALTH_CONFIG:-/etc/nixshare/health.json}"

    if [ ! -r "$config_file" ]; then
      echo "nixshare-health: cannot read config: $config_file (is services.nixshare.health.enable set?)" >&2
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
    state_dir=$(jq -r '.stateDir' "$config_file")
    alert_command=$(jq -r '.alertCommand // empty' "$config_file")

    mkdir -p "$state_dir"

    # Fire the configured alert, if any. Never fatal: an alert channel being
    # down must not stop a recovery that is otherwise working.
    notify() {
      echo "nixshare-health: $1"
      if [ -n "$alert_command" ]; then
        ''${SHELL:-/bin/sh} -c "$alert_command" "nixshare-health" "$1" || \
          echo "nixshare-health: alert command failed (continuing)" >&2
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
    # filtered while 2049 is fine, and vice versa).
    server_reachable() {
      local peer="$1" port="''${2:-2049}"
      timeout 5 bash -c "exec 3<>/dev/tcp/$peer/$port" 2>/dev/null
    }

    # Milliseconds for one cheap metadata op against the mountpoint. Prints
    # the elapsed time; returns non-zero if the op itself failed or timed
    # out (a timeout is the most degraded reading there is, so it counts as
    # the full probe budget rather than as "no data").
    probe_ms() {
      local mp="$1" start end rc
      start=$(date +%s%N)
      timeout "$probe_timeout" stat -c %i "$mp" >/dev/null 2>&1
      rc=$?
      end=$(date +%s%N)
      echo $(( (end - start) / 1000000 ))
      return $rc
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

    # Every mount of a given server shares ONE nfs_client, so `reset-client`
    # can only destroy it if it tears down ALL of them. This lists mounts of
    # `$1` that are live on the box but NOT in the peer group being cured --
    # each one keeps the refcount above zero and makes the cure a silent
    # no-op. nixshare must not unmount what it does not own, so it reports
    # them instead: without this the operator sees a recovery that "ran fine"
    # and changed nothing, with no clue why. Matches on the device prefix as
    # written in /proc/mounts, so a peer named differently there (an IP vs a
    # name) will not be spotted -- stated in README rather than guessed at.
    unmanaged_mounts_for() {
      local peer="$1"; shift
      local managed=" $* " mp
      while read -r dev mp _; do
        case "$dev" in
          "$peer":*) case "$managed" in *" $mp "*) ;; *) echo "$mp" ;; esac ;;
        esac
      done < /proc/mounts
    }

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
      mapfile -t strays < <(unmanaged_mounts_for "$peer" "''${mps[@]}")
      if [ "''${#strays[@]}" -gt 0 ]; then
        notify "$peer -- WARNING: ''${#strays[@]} mount(s) of this server are NOT declared to nixshare: ''${strays[*]}. They share the same nfs_client, so they will hold its refcount above zero and this reset will probably NOT take effect. Declare them as shares of peer '$peer' (or unmount them) for recovery to work."
      fi

      echo "nixshare-health: $peer -- tearing down the shared nfs_client (all ''${#mps[@]} mount(s) + fscache)"

      for mp in "''${mps[@]}"; do
        systemctl stop "$(automount_for "$mp")" 2>/dev/null || true
      done
      for mp in "''${mps[@]}"; do
        systemctl stop "$(unit_for "$mp")" 2>/dev/null || true
        umount -f -l "$mp" 2>/dev/null || true
      done

      cachefilesd_was_active=no
      if systemctl is-active --quiet cachefilesd 2>/dev/null; then
        cachefilesd_was_active=yes
        systemctl stop cachefilesd 2>/dev/null || true
      fi
      # Releases the fscache cookies that keep the nfs_client refcount above
      # zero. Harmless no-op when the module is absent or not in use.
      modprobe -r cachefiles 2>/dev/null || true

      for mp in "''${mps[@]}"; do
        systemctl start "$(unit_for "$mp")" 2>/dev/null || true
      done
      for mp in "''${mps[@]}"; do
        systemctl start "$(automount_for "$mp")" 2>/dev/null || true
      done
      [ "$cachefilesd_was_active" = yes ] && systemctl start cachefilesd 2>/dev/null || true

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
        cause=""
        [ "''${#strays[@]}" -gt 0 ] && cause=" Most likely cause: ''${#strays[@]} undeclared mount(s) of this server (''${strays[*]}) kept the shared nfs_client alive, so it was never destroyed."
        notify "$peer STILL DEGRADED after nfs_client reset ($final mount(s), worst ''${fworst}ms).$cause Manual intervention needed -- a reboot clears client state unconditionally."
      fi
    done
  '';

  meta = with lib; {
    description = "Detect and cure a degraded-but-mounted NFS client (wedged SUNRPC transport state), which the stuck-automount watchdog cannot see";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
