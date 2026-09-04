fixture=$(mktemp -d)
cleanup_fixture() {
  rm -f "$fixture/teardown.success"
  rm -f "$fixture/teardown.failure"
  rm -f "$fixture/teardown.orphan"
  rm -f "$fixture/teardown.orphan-failure"
  rmdir "$fixture"
}
trap cleanup_fixture EXIT

state_dir="$fixture"
calls=()
failed_unit=""

unit_for() { printf 'mount:%s\n' "$1"; }
automount_for() { printf 'automount:%s\n' "$1"; }
systemctl() {
  [ "$1" = start ]
  calls+=("$2")
  [ "$2" != "$failed_unit" ]
}

assert_calls() {
  local expected="$1" actual
  actual=$(printf '%s\n' "${calls[@]}")
  if [ "$actual" != "$expected" ]; then
    echo "unexpected restoration order" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

# Normal completion restores the cache backend, then ALL automounts, then
# ANY mount.  It clears durable and in-memory state only after full success.
teardown_mps=(/mnt/one /mnt/two)
teardown_cachefilesd=yes
teardown_file="$fixture/teardown.success"
printf '%s\n' /mnt/one /mnt/two CACHEFILESD > "$teardown_file"

restore_torn_down
assert_calls "$(printf '%s\n' \
  cachefilesd \
  automount:/mnt/one \
  automount:/mnt/two \
  mount:/mnt/one \
  mount:/mnt/two)"
[ ! -e "$teardown_file" ]
[ "${#teardown_mps[@]}" -eq 0 ]
[ "$teardown_cachefilesd" = no ]

# A failed automount is never followed by its mount.  Other paths are still
# restored, but the marker and armed state remain for a later retry.
calls=()
teardown_mps=(/mnt/one /mnt/two)
teardown_cachefilesd=no
teardown_file="$fixture/teardown.failure"
printf '%s\n' /mnt/one /mnt/two > "$teardown_file"
failed_unit=automount:/mnt/one

if restore_torn_down; then
  echo 'partial restoration was incorrectly reported as successful' >&2
  exit 1
fi
assert_calls "$(printf '%s\n' \
  automount:/mnt/one \
  automount:/mnt/two \
  mount:/mnt/two)"
[ -e "$teardown_file" ]
[ "${#teardown_mps[@]}" -eq 2 ]

# Retrying the same armed state is idempotent and clears it on success.
calls=()
failed_unit=""
restore_torn_down
assert_calls "$(printf '%s\n' \
  automount:/mnt/one \
  automount:/mnt/two \
  mount:/mnt/one \
  mount:/mnt/two)"
[ ! -e "$teardown_file" ]

# Crash/orphan replay must use exactly the same two-phase ordering rather
# than its historical per-path mount-before-automount sequence.
calls=()
printf '%s\n' /mnt/three /mnt/four CACHEFILESD > "$fixture/teardown.orphan"
recover_orphaned_teardowns
assert_calls "$(printf '%s\n' \
  cachefilesd \
  automount:/mnt/three \
  automount:/mnt/four \
  mount:/mnt/three \
  mount:/mnt/four)"
[ ! -e "$fixture/teardown.orphan" ]

# A failed orphan replay remains durable and reports failure to its caller;
# the health tick may not continue into ordinary probing or another reset.
calls=()
printf '%s\n' /mnt/five > "$fixture/teardown.orphan-failure"
failed_unit=mount:/mnt/five
if recover_orphaned_teardowns; then
  echo 'failed orphan restoration was incorrectly reported as successful' >&2
  exit 1
fi
assert_calls "$(printf '%s\n' automount:/mnt/five mount:/mnt/five)"
[ -e "$fixture/teardown.orphan-failure" ]
[ "${teardown_mps[0]}" = /mnt/five ]

calls=()
failed_unit=""
recover_orphaned_teardowns
assert_calls "$(printf '%s\n' automount:/mnt/five mount:/mnt/five)"
[ ! -e "$fixture/teardown.orphan-failure" ]
