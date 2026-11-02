load helpers/fakes

setup() {
  fakes_setup
  export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt" HOMICRON_STATE_DIR="$BATS_TEST_TMPDIR/state" HOMICRON_MANIFEST_DIR="$BATS_TEST_TMPDIR/manifest"
  mkdir -p "$HOMICRON_DIR"
  for f in start-apply.sh homicron-apply.xml; do
    if [[ -f "$BATS_TEST_DIRNAME/../host/$f" ]]; then cp "$BATS_TEST_DIRNAME/../host/$f" "$HOMICRON_DIR/"; fi
  done
  make_fake svccfg
  make_fake svcadm
  make_fake sleep
  # svcs answers from $STATES: one state per line, consumed in order, the
  # last line repeating. svcadm's effect is modeled by listing the state
  # after it as a later line.
  export STATES="$BATS_TEST_TMPDIR/states"
  printf 'disabled\noffline*\n' > "$STATES"
  make_fake svcs
  printf 'n=$(grep -c "^svcs" "$FAKE_LOG"); total=$(wc -l < "$STATES"); (( n > total )) && n=$total; sed -n "${n}p" "$STATES"; exit 0\n' > "$FAKE_BIN/svcs.script"
  # zfs: the dataset exists when $DATASETS lists it.
  export DATASETS="$BATS_TEST_TMPDIR/datasets"; : > "$DATASETS"
  make_fake zfs
  printf 'case $1 in list) grep -qx "${*: -1}" "$DATASETS" ;; create) echo "${*: -1}" >> "$DATASETS" ;; esac\n' > "$FAKE_BIN/zfs.script"
  make_fake kstat 0 $'unix:0:system_misc:boot_time\t1000'
}

@test "manifest is well-formed xml" {
  run xmllint --noout "$BATS_TEST_DIRNAME/../host/homicron-apply.xml"
  [ "$status" -eq 0 ]
}

@test "validates, installs, imports the manifest, writes the marker, enables a disabled service" {
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  assert_called "^svccfg validate $HOMICRON_DIR/homicron-apply.xml$"
  cmp -s "$HOMICRON_DIR/homicron-apply.xml" "$HOMICRON_MANIFEST_DIR/homicron-apply.xml"
  assert_called "^svccfg import $HOMICRON_MANIFEST_DIR/homicron-apply.xml$"
  [[ "$(cat "$HOMICRON_STATE_DIR/apply-requested")" == "1000" ]]
  assert_called '^svcadm enable site/homicron-apply$'
  [[ "$output" == "enabled and started" ]]
}

@test "a validation failure stops before copy, import, or marker" {
  printf 'echo "bad manifest" >&2; exit 1\n' > "$FAKE_BIN/svccfg.script"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad manifest"* ]]
  refute_called '^svccfg import'
  [ ! -e "$HOMICRON_MANIFEST_DIR/homicron-apply.xml" ]
  [ ! -e "$HOMICRON_STATE_DIR/apply-requested" ]
}

@test "maintenance is cleared, online is restarted, a missing service is enabled" {
  for pair in 'maintenance:clear:cleared the failed run and started' 'online:restart:restarted'; do
    IFS=: read -r state verb line <<< "$pair"
    : > "$FAKE_LOG"
    printf '%s\noffline*\n' "$state" > "$STATES"
    run "$HOMICRON_DIR/start-apply.sh"
    [ "$status" -eq 0 ]
    assert_called "^svcadm $verb site/homicron-apply$"
    [[ "$output" == "$line" ]]
  done
  : > "$FAKE_LOG"
  printf "echo \"svcs: Pattern 'site/homicron-apply' doesn't match any instances\" >&2; exit 1\n" > "$FAKE_BIN/svcs.script"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  assert_called '^svcadm enable site/homicron-apply$'
}

@test "waits after svcadm until the state has moved before reporting" {
  printf 'online\nonline\nonline\noffline*\n' > "$STATES"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "restarted" ]]
  [ "$(fake_calls | grep -c '^sleep 0.25$')" -eq 2 ]
  [ "$(fake_calls | grep -c '^svcs')" -eq 4 ]
}

@test "a state that never moves is still reported after the fence gives up" {
  printf 'online\n' > "$STATES"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "restarted" ]]
  [ "$(fake_calls | grep -c '^sleep 0.25$')" -eq 40 ]
}

@test "plain offline (waiting for dependencies) counts as a run in progress" {
  printf 'offline\n' > "$STATES"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
  [[ "$output" == "an apply is already running on the box" ]]
}

@test "creates the rpool/homicron dataset for the state directory once" {
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  assert_called "^zfs create -o mountpoint=$HOMICRON_STATE_DIR rpool/homicron$"
  : > "$FAKE_LOG"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  refute_called '^zfs create'
}

@test "a running method is left alone" {
  printf 'offline*\n' > "$STATES"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
  [[ "$output" == "an apply is already running on the box" ]]
}

@test "an unexpected state is reported and exits 1" {
  printf 'degraded\n' > "$STATES"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *degraded* ]]
}
