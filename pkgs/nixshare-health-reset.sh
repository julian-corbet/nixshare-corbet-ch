# Kernel-state observation used by nixshare-health's reset-client path.
#
# This is kept as a small shell library so the production executable and the
# behavioral fixture execute the same code. The caller supplies the declared
# peer mountpoints, then tears them down, and finally waits for the captured
# NFS client identities to disappear before it remounts anything.

nfs_proc_mountinfo="${NIXSHARE_HEALTH_PROC_MOUNTINFO:-/proc/self/mountinfo}"
nfs_proc_servers="${NIXSHARE_HEALTH_PROC_SERVERS:-/proc/fs/nfsfs/servers}"
nfs_proc_volumes="${NIXSHARE_HEALTH_PROC_VOLUMES:-/proc/fs/nfsfs/volumes}"
nfs_proc_tcp="${NIXSHARE_HEALTH_PROC_TCP:-/proc/net/tcp}"
nfs_proc_tcp6="${NIXSHARE_HEALTH_PROC_TCP6:-/proc/net/tcp6}"

nfs_target_keys=()
nfs_teardown_state="observation-unavailable"

# Capture the exact kernel NFS-client identities backing the declared mount
# roots. Joining mountinfo's device IDs to nfsfs/volumes avoids assuming
# that the configured peer spelling matches the kernel's cl_hostname spelling
# (an address, alias, or canonical name are all possible there). Crossmnt
# children share the root's captured client key, so matching exact declared
# roots also avoids absorbing an unrelated nested NFS mount into this reset.
nixshare_capture_target_nfs_clients() {
  local -a roots=("$@") fields=()
  local line dev mp separator fs_type nv addr port volume_dev _
  local root key i
  local -A target_devs=() seen_keys=()

  nfs_target_keys=()
  nfs_teardown_state="observation-unavailable"

  [ -r "$nfs_proc_mountinfo" ] && [ -r "$nfs_proc_volumes" ] && [ -r "$nfs_proc_servers" ] || return 2

  while IFS= read -r line; do
    read -r -a fields <<< "$line"
    [ "${#fields[@]}" -ge 10 ] || continue
    dev="${fields[2]}"
    mp="${fields[4]}"
    separator=-1
    for ((i = 6; i < ${#fields[@]}; i++)); do
      if [ "${fields[$i]}" = "-" ]; then
        separator=$i
        break
      fi
    done
    [ "$separator" -ge 0 ] || continue
    fs_type="${fields[$((separator + 1))]}"
    case "$fs_type" in nfs|nfs4) ;; *) continue ;; esac

    for root in "${roots[@]}"; do
      if [ "$mp" = "$root" ]; then
        target_devs["$dev"]=1
        break
      fi
    done
  done < "$nfs_proc_mountinfo"

  [ "${#target_devs[@]}" -gt 0 ] || return 1

  while read -r nv addr port volume_dev _; do
    [ -n "$volume_dev" ] || continue
    [ "${target_devs[$volume_dev]+present}" = present ] || continue
    addr="${addr,,}"
    port="${port,,}"
    case "$addr" in ""|*[!0-9a-f]*) continue ;; esac
    case "${#addr}" in 8|32) ;; *) continue ;; esac
    case "$port" in ""|*[!0-9a-f]*) continue ;; esac
    key="$nv|$addr|$port"
    [ "${seen_keys[$key]+present}" = present ] && continue
    seen_keys["$key"]=1
    nfs_target_keys+=("$key")
  done < "$nfs_proc_volumes"

  [ "${#nfs_target_keys[@]}" -gt 0 ] || return 1
  return 0
}

nixshare_count_target_nfs_rows() {
  local file="$1" nv addr port _ key count=0
  local -A wanted=()
  for key in "${nfs_target_keys[@]}"; do
    wanted["$key"]=1
  done
  while read -r nv addr port _; do
    key="$nv|${addr,,}|${port,,}"
    [ "${wanted[$key]+present}" = present ] && count=$((count + 1))
  done < "$file"
  echo "$count"
}

# /proc/net/tcp stores IPv4 bytes in reverse order and IPv6 in reversed
# 32-bit words. nfsfs/servers uses the conventional hexadecimal address.
nixshare_proc_tcp_address() {
  local addr="${1//:/}" group result="" offset
  addr="${addr^^}"
  case "${#addr}" in
    8)
      echo "${addr:6:2}${addr:4:2}${addr:2:2}${addr:0:2}"
      ;;
    32)
      for ((offset = 0; offset < 32; offset += 8)); do
        group="${addr:$offset:8}"
        result+="${group:6:2}${group:4:2}${group:2:2}${group:0:2}"
      done
      echo "$result"
      ;;
    *) return 1 ;;
  esac
}

nixshare_count_target_tcp2049_sockets() {
  local key _ addr _port proc_addr file _sl _local_endpoint remote_endpoint state _rest count=0
  local -A wanted=()

  for key in "${nfs_target_keys[@]}"; do
    IFS='|' read -r _ addr _port <<< "$key"
    proc_addr=$(nixshare_proc_tcp_address "$addr") || continue
    wanted["$proc_addr:0801"]=1
  done

  for file in "$nfs_proc_tcp" "$nfs_proc_tcp6"; do
    [ -r "$file" ] || continue
    while read -r _sl _local_endpoint remote_endpoint state _rest; do
      remote_endpoint="${remote_endpoint^^}"
      [ -n "$remote_endpoint" ] || continue
      # TIME_WAIT is a dead connection record. It cannot retain or recreate
      # an RPC transport, and the reachability gate itself legitimately
      # leaves one behind. Every live/reconnecting state still counts.
      [ "$state" = "06" ] && continue
      [ "${wanted[$remote_endpoint]+present}" = present ] && count=$((count + 1))
    done < "$file"
  done
  echo "$count"
}

nixshare_observe_nfs_teardown() {
  local clients volumes sockets needs_tcp4=no needs_tcp6=no key _ addr _port

  [ -r "$nfs_proc_servers" ] && [ -r "$nfs_proc_volumes" ] || {
    nfs_teardown_state="observation-unavailable=nfsfs"
    return 2
  }

  for key in "${nfs_target_keys[@]}"; do
    IFS='|' read -r _ addr _port <<< "$key"
    case "${#addr}" in
      8) needs_tcp4=yes ;;
      32) needs_tcp6=yes ;;
      *) nfs_teardown_state="observation-unavailable=address"; return 2 ;;
    esac
  done
  if { [ "$needs_tcp4" = yes ] && [ ! -r "$nfs_proc_tcp" ]; } ||
     { [ "$needs_tcp6" = yes ] && [ ! -r "$nfs_proc_tcp6" ]; }; then
    nfs_teardown_state="observation-unavailable=tcp"
    return 2
  fi

  clients=$(nixshare_count_target_nfs_rows "$nfs_proc_servers")
  volumes=$(nixshare_count_target_nfs_rows "$nfs_proc_volumes")
  sockets=$(nixshare_count_target_tcp2049_sockets)
  nfs_teardown_state="retained-nfs-client=$clients retained-nfs-volume=$volumes retained-tcp-2049=$sockets"

  [ "$clients" -eq 0 ] && [ "$volumes" -eq 0 ] && [ "$sockets" -eq 0 ]
}

nixshare_wait_for_nfs_teardown() {
  local timeout_sec="$1" deadline observation_rc
  deadline=$(( $(date +%s) + timeout_sec ))

  while true; do
    if nixshare_observe_nfs_teardown; then
      return 0
    else
      observation_rc=$?
    fi
    [ "$observation_rc" -eq 2 ] && return 1
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}
