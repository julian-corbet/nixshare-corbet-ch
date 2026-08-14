fixture=$(mktemp -d)
cleanup_fixture() {
  rm -f "$fixture/mountinfo"
  rm -f "$fixture/servers"
  rm -f "$fixture/volumes"
  rm -f "$fixture/tcp"
  rm -f "$fixture/tcp6"
  rmdir "$fixture"
}
trap cleanup_fixture EXIT

nfs_proc_mountinfo="$fixture/mountinfo"
nfs_proc_servers="$fixture/servers"
nfs_proc_volumes="$fixture/volumes"
nfs_proc_tcp="$fixture/tcp"
nfs_proc_tcp6="$fixture/tcp6"

printf '%s\n' \
  '36 25 0:42 / /mnt/example rw,relatime shared:1 - nfs4 storage-host:/export rw' \
  > "$nfs_proc_mountinfo"
printf '%s\n' \
  'NV SERVER   PORT USE HOSTNAME' \
  'v4 c000020a 801 1 storage-host' \
  > "$nfs_proc_servers"
printf '%s\n' \
  'NV SERVER   PORT DEV          FSID                              FSC' \
  'v4 c000020a 801 0:42         1:2                               no' \
  > "$nfs_proc_volumes"
printf '%s\n' \
  '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode' \
  > "$nfs_proc_tcp"
printf '%s\n' \
  '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode' \
  > "$nfs_proc_tcp6"

nixshare_capture_target_nfs_clients /mnt/example
[ "${#nfs_target_keys[@]}" -eq 1 ]
[ "${nfs_target_keys[0]}" = 'v4|c000020a|801' ]
[ "$(nixshare_proc_tcp_address c000020a)" = '0A0200C0' ]
[ "$(nixshare_proc_tcp_address 20010db8000000000000000000000001)" = 'B80D0120000000000000000001000000' ]

# A complete teardown ignores unrelated clients and the reachability probe's
# dead TIME_WAIT record, while requiring every live target record to be gone.
printf '%s\n' \
  'NV SERVER   PORT USE HOSTNAME' \
  'v4 c0000214 801 1 other-host' \
  > "$nfs_proc_servers"
printf '%s\n' \
  'NV SERVER   PORT DEV          FSID                              FSC' \
  'v4 c0000214 801 0:99         3:4                               no' \
  > "$nfs_proc_volumes"
printf '%s\n' \
  '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode' \
  '   0: 0100007F:C350 0A0200C0:0801 06 00000000:00000000 03:00000000 00000000 0 0 0' \
  '   1: 0100007F:C351 140200C0:0801 01 00000000:00000000 00:00000000 00000000 0 0 0' \
  > "$nfs_proc_tcp"

nixshare_wait_for_nfs_teardown 1
[ "$nfs_teardown_state" = 'retained-nfs-client=0 retained-nfs-volume=0 retained-tcp-2049=0' ]

# An open reference retains all three kernel views. The bounded wait must
# fail with typed counts; a caller can restore mounts but may not call this a
# completed reset.
printf '%s\n' \
  'NV SERVER   PORT USE HOSTNAME' \
  'v4 c000020a 801 2 storage-host' \
  > "$nfs_proc_servers"
printf '%s\n' \
  'NV SERVER   PORT DEV          FSID                              FSC' \
  'v4 c000020a 801 0:42         1:2                               no' \
  > "$nfs_proc_volumes"
printf '%s\n' \
  '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode' \
  '   0: 0100007F:C350 0A0200C0:0801 01 00000000:00000000 00:00000000 00000000 0 0 0' \
  > "$nfs_proc_tcp"

if nixshare_wait_for_nfs_teardown 1; then
  echo 'retained NFS references were incorrectly accepted as a complete teardown' >&2
  exit 1
fi
[ "$nfs_teardown_state" = 'retained-nfs-client=1 retained-nfs-volume=1 retained-tcp-2049=1' ]
