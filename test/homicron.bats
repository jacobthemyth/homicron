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
  assert_called '^ssh -p 2222 root@box.local /opt/homicron/run-step.sh 10-a.sh$'
  assert_called '^ssh -p 2222 root@box.local /opt/homicron/run-step.sh 20-b.sh$'
  [[ "$(fake_calls | grep run-step | head -1)" == *10-a.sh ]]
  [[ "${lines[-3]}" == "apply complete" ]]
}

@test "exit 10 reboots, waits, reruns the step, then continues" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
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

@test "ssh subcommand uses the user and port" {
  run "$REPO/bin/homicron" ssh box
  assert_called '^ssh -p 2222 jacob@box.local$'
}
