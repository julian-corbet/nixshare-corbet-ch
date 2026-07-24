# pkgs/nixshare-watchdog.nix
#
# The watchdog's entire implementation: a single, generic, config-driven
# shell tool. Every share-specific fact (mountpoint, per-share timeout, the
# alert command) lives in the JSON file it reads at runtime
# (/etc/nixshare/watchdog.json, rendered by modules/core.nix) -- this
# script itself carries zero nixshare-specific literals, mirroring how
# nixnetd is entirely Nix-unaware and only ever reads /etc/nixnet/config.json.
#
# WHY SHELL, NOT RUST (project default is Rust/web languages): this is
# invoked fresh, to completion, by a systemd *oneshot* on a timer -- one
# pass, no in-memory state carried between ticks, process exits every
# time. That is exactly the "stateless one-shot CLI/shell-glue" carve-out
# the standing language policy already makes room for (nixpush's own
# `nixpush` CLI -- pkgs/nixpush.nix -- is the precedent: also a oneshot
# invoked from systemd/shell call sites, also a real writeShellApplication,
# not a stub). A genuinely resident, long-running process (more like
# nixnetd itself) would warrant Rust; this tool is never that -- it reads
# systemd's own unit-state tracking fresh every tick instead of keeping
# any of its own.
#
# WHAT IT ACTUALLY DOES, per configured share, every tick:
#   1. Resolve the share's mountpoint to its systemd `.mount` unit name via
#      `systemd-escape` (the real command, not a hand-rolled reimplementation
#      of systemd's escaping rules -- see modules/core.nix's own comment on
#      why this is deliberately NOT computed at Nix-eval time).
#   2. If that unit is not currently `activating` (i.e. no establish attempt
#      is in flight right now), skip it -- nothing to do.
#   3. If it IS `activating`, compute how long it's been so via
#      `InactiveExitTimestamp` (the moment it left `inactive`, i.e. began
#      trying to establish).
#   4. If that duration has crossed the share's own `automountTimeoutSec`,
#      the attempt is stuck -- `umount -f -l` the mountpoint directly. This
#      is a VFS-level operation, independent of whatever the blocked
#      mount(8) helper process is doing kernel-side (which may be
#      uninterruptibly stuck and un-killable, hence "before it hangs the
#      session" instead of trying to be gentler first) -- exactly the
#      manual "polkit password + sudo umount -f -l" recovery this replaces.
#   5. `systemctl reset-failed` the unit as a courtesy (harmless if it
#      never actually reached `failed`), then fire the configured alert.
{ lib, writeShellApplication, jq, systemd, util-linux, coreutils }:

writeShellApplication {
  name = "nixshare-watchdog";
  runtimeInputs = [ jq systemd util-linux coreutils ];
  text = ''
    # nixshare-watchdog -- see pkgs/nixshare-watchdog.nix and README.md
    # "How the watchdog works" for the full explanation.

    config_file="''${NIXSHARE_WATCHDOG_CONFIG:-/etc/nixshare/watchdog.json}"

    if [ ! -r "$config_file" ]; then
      echo "nixshare-watchdog: cannot read config: $config_file (is services.nixshare.enable set?)" >&2
      exit 1
    fi

    if ! jq -e . >/dev/null 2>&1 < "$config_file"; then
      echo "nixshare-watchdog: config is not valid JSON: $config_file" >&2
      exit 1
    fi

    alert_cmd=$(jq -r '.alertCommand // empty' "$config_file")

    # $1 = human-readable alert message. Always logged to the journal
    # (stdout of a systemd oneshot lands there automatically); additionally
    # handed to alert_cmd, if one is configured, via eval -- alert_cmd
    # itself is a Nix-eval-time-trusted, already-shell-escaped command
    # PREFIX (see modules/core.nix's `watchdog.alertCommand` option and
    # nixpush's own `mkSendCommand` helper, which is exactly what most
    # deployments will bake it from); the runtime-computed message is the
    # only untrusted-shaped piece, so it alone is quoted here via `%q`
    # before being appended and eval'd.
    send_alert() {
      local message="$1"
      echo "nixshare-watchdog: ALERT: $message"
      if [ -n "$alert_cmd" ]; then
        # shellcheck disable=SC2086
        if ! eval "$alert_cmd $(printf '%q' "$message")"; then
          echo "nixshare-watchdog: alert command exited non-zero (continuing -- a failed alert must never block recovery)" >&2
        fi
      fi
    }

    share_count=$(jq -r '.shares | length' "$config_file")
    if [ "$share_count" -eq 0 ]; then
      exit 0
    fi

    # Read every share as one JSON line per share (jq -c), then loop over
    # a process-substituted stream rather than piping into `while read`
    # directly -- a plain pipe puts the loop body in a subshell under
    # `set -o pipefail`-style bash, which is harmless here (no variables
    # need to escape the loop) but process substitution is the more
    # obviously-correct habit and costs nothing.
    while IFS= read -r share_json; do
      name=$(jq -r '.name' <<<"$share_json")
      mountpoint=$(jq -r '.mountpoint' <<<"$share_json")
      timeout=$(jq -r '.automountTimeoutSec' <<<"$share_json")

      unit=$(systemd-escape --path --suffix=mount "$mountpoint")

      active_state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo "")
      if [ "$active_state" != "activating" ]; then
        continue
      fi

      since=$(systemctl show -p InactiveExitTimestamp --value "$unit" 2>/dev/null || echo "")
      if [ -z "$since" ]; then
        continue
      fi
      since_epoch=$(date -d "$since" +%s 2>/dev/null || echo 0)
      if [ "$since_epoch" -le 0 ]; then
        continue
      fi

      now_epoch=$(date +%s)
      elapsed=$((now_epoch - since_epoch))

      if [ "$elapsed" -ge "$timeout" ]; then
        echo "nixshare-watchdog: share '$name' ($mountpoint, unit $unit) has been activating for ''${elapsed}s (>= ''${timeout}s) -- force-lazy-unmounting"
        if umount -f -l "$mountpoint" 2>&1; then
          echo "nixshare-watchdog: umount -f -l $mountpoint succeeded"
        else
          echo "nixshare-watchdog: umount -f -l $mountpoint reported an error (mountpoint may already have cleared -- continuing)" >&2
        fi
        systemctl reset-failed "$unit" 2>/dev/null || true
        send_alert "nixshare: force-unmounted stuck share '$name' at $mountpoint on $HOSTNAME after ''${elapsed}s (threshold ''${timeout}s)"
      fi
    done < <(jq -c '.shares[]' "$config_file")
  '';

  meta = with lib; {
    description = "Config-driven watchdog: force-unmounts a nixshare automount that has been establishing longer than its configured timeout";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
