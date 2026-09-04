# Crash-safe restoration shared by the live health monitor and its fixture.
#
# The order is load-bearing.  An automount is the durable owner of the path:
# once it is active, a failed or idle mount can be established again by the
# next access.  Starting the mount first leaves no trigger behind if that
# start fails or the recovery process is interrupted.  Start every automount
# before attempting any mount, and keep the on-disk teardown marker until all
# requested units have been restored successfully.

restore_torn_down() {
  if [ "${#teardown_mps[@]}" -eq 0 ] && [ "$teardown_cachefilesd" != yes ]; then
    return 0
  fi

  echo "nixshare-health: restoring ${#teardown_mps[@]} mount(s) torn down by recovery"

  local mp unit restore_failed=no
  local -A automount_ready=()

  # Restore the cache backend before mounts which may have `fsc` in their
  # options.  Failure does not prevent the path-owning automounts below from
  # being restored.
  if [ "$teardown_cachefilesd" = yes ]; then
    if ! systemctl start cachefilesd 2>/dev/null; then
      echo "nixshare-health: failed to restore cachefilesd; teardown marker retained" >&2
      restore_failed=yes
    fi
  fi

  # Two separate loops are intentional: every path regains its automount
  # trigger before any potentially slow or failing network mount is started.
  for mp in "${teardown_mps[@]}"; do
    unit=$(automount_for "$mp")
    if systemctl start "$unit" 2>/dev/null; then
      automount_ready["$mp"]=1
    else
      echo "nixshare-health: failed to restore automount $unit; teardown marker retained" >&2
      restore_failed=yes
    fi
  done

  for mp in "${teardown_mps[@]}"; do
    # Do not establish a mount with no automount left to own and re-trigger
    # its path later.  The failed marker makes the next health tick retry.
    [ "${automount_ready[$mp]+present}" = present ] || continue
    unit=$(unit_for "$mp")
    if ! systemctl start "$unit" 2>/dev/null; then
      echo "nixshare-health: failed to restore mount $unit; teardown marker retained" >&2
      restore_failed=yes
    fi
  done

  [ "$restore_failed" = no ] || return 1

  teardown_mps=()
  teardown_cachefilesd=no
  [ -n "${teardown_file:-}" ] && rm -f "$teardown_file"
  teardown_file=""
  return 0
}

recover_orphaned_teardowns() {
  local f mp
  for f in "$state_dir"/teardown.*; do
    [ -e "$f" ] || continue
    echo "nixshare-health: found an interrupted teardown ($f) -- restoring its mounts first" >&2

    teardown_mps=()
    teardown_cachefilesd=no
    teardown_file="$f"
    while IFS= read -r mp; do
      case "$mp" in
        "") continue ;;
        "CACHEFILESD") teardown_cachefilesd=yes ;;
        *) teardown_mps+=("$mp") ;;
      esac
    done < "$f"

    if [ "${#teardown_mps[@]}" -eq 0 ] && [ "$teardown_cachefilesd" != yes ]; then
      echo "nixshare-health: interrupted teardown marker is empty; retaining it and refusing further recovery: $f" >&2
      return 1
    fi

    # A failed restore must stop this tick before it probes or tears down
    # anything else.  restore_torn_down leaves both memory and disk state
    # armed so ExecStopPost or the next tick can retry.
    restore_torn_down || return 1
  done
}
