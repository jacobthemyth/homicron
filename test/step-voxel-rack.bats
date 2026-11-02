load helpers/fakes

setup() {
  fakes_setup
  export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt" HOMICRON_MANIFEST_DIR="$BATS_TEST_TMPDIR/manifest"
  export VOXEL_RACK=yes
  mkdir -p "$HOMICRON_DIR" "$HOMICRON_MANIFEST_DIR"
  for f in 90-voxel-rack.sh lib.sh voxel-rack.xml voxel-rack-start.sh voxel-rack-stop.sh; do
    if [[ -f "$BATS_TEST_DIRNAME/../host/$f" ]]; then cp "$BATS_TEST_DIRNAME/../host/$f" "$HOMICRON_DIR/"; fi
  done
  STEP="$HOMICRON_DIR/90-voxel-rack.sh"
  make_fake svccfg
  make_fake svcadm
  # svcs answers with the content of $STATES; svcadm enable or disable rewrites it.
  export STATES="$BATS_TEST_TMPDIR/states"
  echo disabled > "$STATES"
  make_fake svcs
  printf 'cat "$STATES"\n' > "$FAKE_BIN/svcs.script"
  printf 'case $1 in enable|clear) echo online > "$STATES" ;; disable) echo disabled > "$STATES" ;; esac\n' > "$FAKE_BIN/svcadm.script"
  make_fake sleep
}

@test "a service in maintenance is cleared, not enabled again" {
  cp "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/"
  echo maintenance > "$STATES"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^svcadm clear site/voxel-rack$'
  refute_called '^svcadm enable'
  [[ "$output" == *"voxel-rack cleared; the launch retries under svc:/site/voxel-rack"* ]]
}

@test "waits for startd to move the instance after svcadm" {
  # svcadm returns before the state changes: the fake flips the state only
  # on the third svcs call after it.
  printf 'n=$(grep -c "^svcs" "$FAKE_LOG"); if grep -q "^svcadm enable" "$FAKE_LOG" && (( n >= 4 )); then echo online; else cat "$STATES"; fi\n' > "$FAKE_BIN/svcs.script"
  printf 'exit 0\n' > "$FAKE_BIN/svcadm.script"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^svcadm enable site/voxel-rack$'
  assert_called '^sleep '
}

@test "VOXEL_RACK other than yes or no exits 1 and touches nothing" {
  cp "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/"
  echo online > "$STATES"
  VOXEL_RACK=true run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VOXEL_RACK must be yes or no, not true"* ]]
  refute_called '^svcadm'
}

@test "validates, installs, imports, and enables" {
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called "^svccfg validate $HOMICRON_DIR/voxel-rack.xml$"
  cmp -s "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/voxel-rack.xml"
  assert_called "^svccfg import $HOMICRON_MANIFEST_DIR/voxel-rack.xml$"
  assert_called '^svcadm enable site/voxel-rack$'
  [[ "$output" == *"voxel-rack enabled; the launch runs under svc:/site/voxel-rack, log /var/log/voxel-rack.log"* ]]
}

@test "a validation failure changes nothing and exits 1" {
  printf 'echo bad >&2; exit 1\n' > "$FAKE_BIN/svccfg.script"
  run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *bad* ]]
  [ ! -e "$HOMICRON_MANIFEST_DIR/voxel-rack.xml" ]
  refute_called '^svccfg import'
  refute_called '^svcadm'
}

@test "VOXEL_RACK=no disables an enabled service" {
  cp "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/"
  echo online > "$STATES"
  VOXEL_RACK=no run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^svcadm disable site/voxel-rack$'
  refute_called '^svccfg'
}

@test "VOXEL_RACK=no on a disabled service runs nothing" {
  cp "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/"
  VOXEL_RACK=no run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
}

@test "already installed and enabled: nothing runs" {
  cp "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/"
  echo online > "$STATES"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
  refute_called '^svccfg'
}

@test "a launching service counts as enabled" {
  cp "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/"
  echo 'offline*' > "$STATES"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
}

@test "a changed manifest is validated, copied, and imported without touching an enabled service" {
  echo '<!-- old -->' > "$HOMICRON_MANIFEST_DIR/voxel-rack.xml"
  echo online > "$STATES"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^svccfg validate'
  assert_called '^svccfg import'
  cmp -s "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/voxel-rack.xml"
  refute_called '^svcadm'
}
