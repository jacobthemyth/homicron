load helpers/fakes

HOST="$BATS_TEST_DIRNAME/../host"

setup() {
  fakes_setup
  export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt" HOMICRON_HOME="$BATS_TEST_TMPDIR/home"
  export HOMICRON_RACK_LOG="$BATS_TEST_TMPDIR/rack.log"
  mkdir -p "$HOMICRON_DIR"
  printf 'HOMICRON_USER=vmuser\n' > "$HOMICRON_DIR/host.env"
  SRC="$HOMICRON_HOME/vmuser/src/voxel"
  CONFIG="$HOMICRON_HOME/vmuser/.config/voxel"
  mkdir -p "$SRC/target/release" "$CONFIG"
  make_fake su
  printf 'while [[ $1 != -c ]]; do shift; done; printf "%%s\\n" "$2" >> "$FAKE_LOG.su"; HOME="$HOMICRON_HOME/$HOMICRON_USER" bash -c "$2"\n' > "$FAKE_BIN/su.script"
  make_fake pfexec
  printf '"$@"\n' > "$FAKE_BIN/pfexec.script"
  # A fake voxel at the real path: `launch` prints $LAUNCH_OUT, `destroy` only logs.
  export LAUNCH_OUT="$BATS_TEST_TMPDIR/launch-out"
  printf 'rack-init: complete, rack initialized\nlaunch complete\n' > "$LAUNCH_OUT"
  cat > "$SRC/target/release/voxel" <<EOS
#!/bin/bash
printf '%s\n' "voxel \$*" >> "$FAKE_LOG"
case "\$1" in
  launch) cat "$LAUNCH_OUT" ;;
esac
exit 0
EOS
  chmod +x "$SRC/target/release/voxel"
}

@test "manifest is well-formed xml and names the two methods and the apply dependency" {
  run xmllint --noout "$HOST/voxel-rack.xml"
  [ "$status" -eq 0 ]
  grep -q "exec='/opt/homicron/voxel-rack-start.sh'" "$HOST/voxel-rack.xml"
  grep -q "exec='/opt/homicron/voxel-rack-stop.sh'" "$HOST/voxel-rack.xml"
  grep -q "svc:/site/homicron-apply:default" "$HOST/voxel-rack.xml"
  grep -q "timeout_seconds='2400'" "$HOST/voxel-rack.xml"
  grep -q "enabled='false'" "$HOST/voxel-rack.xml"
  grep -q "value='transient'" "$HOST/voxel-rack.xml"
}

@test "start: no workspace, launch ok: no destroy, launch as the user, exit 0, header in the log" {
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 0 ]
  refute_called 'voxel destroy'
  assert_called '^su - vmuser -c pfexec .*voxel launch$'
  grep -q '^=== start ' "$HOMICRON_RACK_LOG"
  grep -q 'launch complete' "$HOMICRON_RACK_LOG"
}

@test "start: a workspace is destroyed first" {
  mkdir -p "$CONFIG/.falcon"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 0 ]
  [[ "$(fake_calls | grep -oE '^voxel (destroy|launch)' | tr '\n' '|')" == 'voxel destroy|voxel launch|' ]]
  grep -q 'destroying the previous rack' "$HOMICRON_RACK_LOG"
}

@test "start: rack-init FAILED exits 95 even when launch complete follows" {
  printf 'rack-init FAILED: Bootstore error\nlaunch complete\n' > "$LAUNCH_OUT"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 95 ]
  grep -q 'launch failed; see above' "$HOMICRON_RACK_LOG"
}

@test "start: missing launch complete exits 95" {
  : > "$LAUNCH_OUT"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 95 ]
}

@test "start: missing host.env exits 96 and runs nothing" {
  rm "$HOMICRON_DIR/host.env"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 96 ]
  refute_called '^su'
}

@test "start: the hook runs as the user after success, and its failure keeps exit 0" {
  printf '#!/bin/bash\necho hook ran; exit 3\n' > "$CONFIG/post-launch.sh"; chmod +x "$CONFIG/post-launch.sh"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 0 ]
  grep -q 'hook ran' "$HOMICRON_RACK_LOG"
  grep -q 'post-launch.sh exited 3' "$HOMICRON_RACK_LOG"
  assert_called '^su - vmuser -c .*post-launch.sh'
}

@test "start: a hook that is not executable does not run" {
  printf 'echo hook ran\n' > "$CONFIG/post-launch.sh"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 0 ]
  ! grep -q 'hook ran' "$HOMICRON_RACK_LOG"
}

@test "start: a failed launch does not run the hook" {
  printf '#!/bin/bash\necho hook ran\n' > "$CONFIG/post-launch.sh"; chmod +x "$CONFIG/post-launch.sh"
  : > "$LAUNCH_OUT"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 95 ]
  ! grep -q 'hook ran' "$HOMICRON_RACK_LOG"
}

@test "stop: destroys when the workspace exists, exits 0 either way" {
  run "$HOST/voxel-rack-stop.sh"
  [ "$status" -eq 0 ]
  refute_called 'voxel destroy'
  mkdir -p "$CONFIG/.falcon"
  run "$HOST/voxel-rack-stop.sh"
  [ "$status" -eq 0 ]
  assert_called '^su - vmuser -c pfexec .*voxel destroy$'
}
