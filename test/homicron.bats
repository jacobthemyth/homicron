load helpers/fakes

BIN="$BATS_TEST_DIRNAME/../bin/homicron"

setup() {
  fakes_setup
  export REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/hosts" "$REPO/host" "$REPO/keys" "$REPO/bin"
  if [[ -f $BIN ]]; then cp "$BIN" "$REPO/bin/homicron"; fi
  : > "$REPO/keys/authorized_keys"
  printf 'HOMICRON_USER=jacob\nHOMICRON_UID=501\nHOMICRON_PORT=2222\n' > "$REPO/hosts/box.env"
  printf '#!/bin/bash\n' > "$REPO/host/10-a.sh"
  printf '#!/bin/bash\n' > "$REPO/host/20-b.sh"
  make_fake rsync
  make_fake ssh
  export HOMICRON_POLL_SECONDS=0 HOMICRON_REBOOT_TIMEOUT=1
  unset HOMICRON_ADDR
}

@test "missing host file or required variable exits 2 before rsync" {
  run "$REPO/bin/homicron" apply nope
  [ "$status" -eq 2 ]
  printf 'HOMICRON_USER=jacob\n' > "$REPO/hosts/bad.env"
  run "$REPO/bin/homicron" apply bad
  [ "$status" -eq 2 ]
  refute_called '^rsync'
}

@test "environment wins over the host file" {
  HOMICRON_ADDR=10.9.9.9 run "$REPO/bin/homicron" apply box
  assert_called 'root@10.9.9.9'
  refute_called 'box\.local'
}

@test "runs steps in order over ssh with the port" {
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^ssh -p 2222 .*root@box.local /opt/homicron/run-step.sh 10-a.sh$'
  assert_called '^ssh -p 2222 .*root@box.local /opt/homicron/run-step.sh 20-b.sh$'
  [[ "$(fake_calls | grep run-step | head -1)" == *10-a.sh ]]
  [[ "${lines[-3]}" == "apply complete" ]]
  [[ "${lines[-1]}" == '  pfexec ~/src/voxel/target/release/voxel image create && pfexec ~/src/voxel/target/release/voxel image create-frr proto' ]]
}

@test "exit 10 reboots, waits, reruns the step, then continues" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) n=$(grep -c 'reboot$' "$FAKE_LOG"); printf 'unix:0:system_misc:boot_time\t%s\n' "$((1000 + n))"; exit 0 ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called 'root@box.local reboot$'
  assert_called '^ssh .*-o ServerAliveInterval=[0-9]+ .*root@box.local reboot$'
  [ "$(fake_calls | grep -c '10-a.sh$')" -eq 2 ]
  assert_called '20-b.sh$'
}

@test "an unchanged boot time means the reboot was lost; it is sent again" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) n=$(grep -c 'kstat' "$FAKE_LOG"); if (( n <= 2 )); then t=1000; else t=1001; fi; printf 'unix:0:system_misc:boot_time\t%s\n' "$t"; exit 0 ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [ "$(fake_calls | grep -c 'reboot$')" -eq 2 ]
  [[ "$output" == *"has not rebooted yet"* ]]
  [ "$(fake_calls | grep -c '10-a.sh$')" -eq 2 ]
}

@test "a failing kstat still reboots, waits for ssh, and reruns the step" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) exit 1 ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called 'root@box.local reboot$'
  [ "$(fake_calls | grep -c '10-a.sh$')" -eq 2 ]
}

@test "exit 255 reports unreachable and exits 1" {
  make_fake ssh 255
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local"* ]]
}

@test "other failures stop, print the log, and pass the status through" {
  printf 'case "$*" in *10-a.sh) exit 3;; *cat*) echo LOGLINE; exit 0;; *) exit 0;; esac\n' > "$FAKE_BIN/ssh.script"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 3 ]
  [[ "$output" == *LOGLINE* ]]
  [[ "$output" == *"step 10-a.sh failed with status 3" ]]
  refute_called '20-b.sh$'
}

@test "ssh subcommand uses the user and port, without keepalives" {
  run "$REPO/bin/homicron" ssh box
  assert_called '^ssh -p 2222 .*jacob@box.local$'
  refute_called 'ServerAlive.*jacob@box.local$'
}

@test "every ssh and the rsync transport carry keepalives" {
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^ssh -p 2222 -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@box.local /opt/homicron/run-step.sh 10-a.sh$'
  assert_called '^rsync .* -e ssh -p 2222 -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 .*host.env$'
}

@test "an rsync failure that is not 255 is reported as rsync, not as unreachable" {
  make_fake rsync 127
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"rsync failed with status 127"* ]]
  [[ "$output" != *"cannot reach"* ]]
  refute_called '^ssh'
}

@test "sends a resolved host.env with defaults and environment overrides" {
  cat > "$FAKE_BIN/rsync.script" <<'EOS'
dest="${*: -1}"; src="${*: -2:1}"
if [[ $dest == *host.env ]]; then cp "$src" "$BATS_TEST_TMPDIR/sent.env"; fi
exit 0
EOS
  VOXEL_REF=v0.9 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  grep -qx 'SWAP_SIZE=16G' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_REF=v0.9' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'HOMICRON_USER=jacob' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'FALCON_DATASET=' "$BATS_TEST_TMPDIR/sent.env"
}

@test "malformed hosts lines exit 2 with the line number before rsync" {
  for bad in '  HOMICRON_UID=501' 'export HOMICRON_ADDR=box.lan' 'HOMICRON_ADDR' 'HOMICRON_ADDR=box.lan # lab' 'HOMICRON_PORT="2222"' $'HOMICRON_PORT=2222\r' 'HOMICRON_ADDR=box;reboot' 'VOXEL_REF=main|true' 'FALCON_DATASET=~/falcon'; do
    printf 'HOMICRON_USER=jacob\nHOMICRON_UID=501\n%s\n' "$bad" > "$REPO/hosts/bad.env"
    run "$REPO/bin/homicron" apply bad
    [ "$status" -eq 2 ]
    [[ "$output" == *"bad.env line 3"* ]]
  done
  refute_called '^rsync'
}

@test "a value from the environment with shell characters exits 2 before rsync" {
  HOMICRON_ADDR='box.lan # lab' run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOMICRON_ADDR"* ]]
  refute_called '^rsync'
}

@test "rsync failing to connect reports unreachable and never runs a step" {
  make_fake rsync 255
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local"* ]]
  refute_called '^ssh'
}
