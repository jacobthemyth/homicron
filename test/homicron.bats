load helpers/fakes

BIN="$BATS_TEST_DIRNAME/../bin/homicron"

setup() {
  fakes_setup
  export REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/hosts" "$REPO/host" "$REPO/bin"
  if [[ -f $BIN ]]; then cp "$BIN" "$REPO/bin/homicron"; fi
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  printf 'ssh-ed25519 AAAA workstation\n' > "$HOME/.ssh/id_ed25519.pub"
  unset HOMICRON_KEYS
  printf 'HOMICRON_USER=vmuser\nHOMICRON_UID=501\nHOMICRON_PORT=2222\n' > "$REPO/hosts/box.env"
  printf '#!/bin/bash\n' > "$REPO/host/10-a.sh"
  printf '#!/bin/bash\n' > "$REPO/host/20-b.sh"
  make_fake rsync
  make_fake ssh
  export HOMICRON_POLL_SECONDS=0 HOMICRON_REBOOT_TIMEOUT=1 HOMICRON_REBOOT_GRACE=0
  unset HOMICRON_ADDR
}

# A fake rsync that keeps a copy of the shipped host.env and authorized_keys.
capture_sent() {
  cat > "$FAKE_BIN/rsync.script" <<'EOS'
dest="${*: -1}"; src="${*: -2:1}"
case "$dest" in *host.env) cp "$src" "$BATS_TEST_TMPDIR/sent.env" ;; *authorized_keys) cp "$src" "$BATS_TEST_TMPDIR/sent.keys" ;; esac
exit 0
EOS
}

@test "missing host file exits 2 before rsync" {
  run "$REPO/bin/homicron" apply nope
  [ "$status" -eq 2 ]
  refute_called '^rsync'
}

@test "login and uid default to the workstation's" {
  printf 'HOMICRON_PORT=2222\n' > "$REPO/hosts/plain.env"
  capture_sent
  run "$REPO/bin/homicron" apply plain
  [ "$status" -eq 0 ]
  grep -qx "HOMICRON_USER=$(id -un)" "$BATS_TEST_TMPDIR/sent.env"
  grep -qx "HOMICRON_UID=$(id -u)" "$BATS_TEST_TMPDIR/sent.env"
}

@test "a root login or uid 0 exits 2 before rsync" {
  HOMICRON_USER=root run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"root"* ]]
  HOMICRON_UID=0 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  refute_called '^rsync'
}

@test "a uid that is not a positive integer exits 2 before rsync" {
  for bad in 00 000 5a -1; do
    HOMICRON_UID=$bad run "$REPO/bin/homicron" apply box
    [ "$status" -eq 2 ]
    [[ "$output" == *"HOMICRON_UID=$bad"* ]]
  done
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

@test "within the grace period an unchanged boot time does not resend reboot" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) printf 'unix:0:system_misc:boot_time\t1000\n'; exit 0 ;;
  *10-a.sh) exit 10 ;;
  *) exit 0 ;;
esac
EOS
  HOMICRON_REBOOT_GRACE=60 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local after reboot"* ]]
  [ "$(fake_calls | grep -c 'reboot$')" -eq 1 ]
}

@test "a failing kstat still reboots, waits for ssh to drop and return, and reruns the step" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) exit 1 ;;
  *root@box.local\ true) n=$(grep -c 'true$' "$FAKE_LOG"); if (( n <= 2 )); then exit 255; else exit 0; fi ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called 'root@box.local reboot$'
  [ "$(fake_calls | grep -c '10-a.sh$')" -eq 2 ]
}

@test "without kstat, ssh that never drops means the reboot was lost; it is sent again" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) exit 1 ;;
  *root@box.local\ true) n=$(grep -c 'reboot$' "$FAKE_LOG"); if (( n >= 2 )); then exit 255; else exit 0; fi ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
  HOMICRON_REBOOT_TIMEOUT=2 run "$REPO/bin/homicron" apply box
  [ "$(fake_calls | grep -c 'reboot$')" -ge 2 ]
  [[ "$output" == *"has not rebooted yet"* ]]
}

@test "an unknown variable in the hosts file exits 2 with the line number before rsync" {
  printf 'HOMICRON_USER=vmuser\nHOMICRON_UID=501\nVOXEL_SLED=8\n' > "$REPO/hosts/typo.env"
  run "$REPO/bin/homicron" apply typo
  [ "$status" -eq 2 ]
  [[ "$output" == *"typo.env line 3"* ]]
  [[ "$output" == *"VOXEL_SLED"* ]]
  refute_called '^rsync'
}

@test "exit 255 reports unreachable and exits 1" {
  make_fake ssh 255
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local"* ]]
  [[ "$output" == *"host key"* ]]
  [[ "$output" == *"ssh root@box.local"* ]]
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
  assert_called '^ssh -p 2222 .*vmuser@box.local$'
  refute_called 'ServerAlive.*vmuser@box.local$'
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
  capture_sent
  VOXEL_REF=v0.9 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  grep -qx 'SWAP_SIZE=16G' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_REF=v0.9' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'HOMICRON_USER=vmuser' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'FALCON_DATASET=' "$BATS_TEST_TMPDIR/sent.env"
}

@test "malformed hosts lines exit 2 with the line number before rsync" {
  for bad in '  HOMICRON_UID=501' 'export HOMICRON_ADDR=box.lan' 'HOMICRON_ADDR' 'HOMICRON_ADDR=box.lan # lab' 'HOMICRON_PORT="2222"' $'HOMICRON_PORT=2222\r' 'HOMICRON_ADDR=box;reboot' 'VOXEL_REF=main|true' 'FALCON_DATASET=~/falcon'; do
    printf 'HOMICRON_USER=vmuser\nHOMICRON_UID=501\n%s\n' "$bad" > "$REPO/hosts/bad.env"
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
  [[ "$output" == *"host key"* ]]
  [[ "$output" == *"ssh root@box.local"* ]]
  refute_called '^ssh'
}

@test "by default the shipped keys are every ~/.ssh/*.pub, each ending in a newline, certificates skipped" {
  printf 'ssh-rsa BBBB second' > "$HOME/.ssh/id_rsa.pub"
  printf 'ssh-ed25519-cert-v01@openssh.com CCCC cert\n' > "$HOME/.ssh/id_ed25519-cert.pub"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/sent.keys" | tr -d ' ')" -eq 2 ]
  grep -qx 'ssh-ed25519 AAAA workstation' "$BATS_TEST_TMPDIR/sent.keys"
  grep -qx 'ssh-rsa BBBB second' "$BATS_TEST_TMPDIR/sent.keys"
  ! grep -q CCCC "$BATS_TEST_TMPDIR/sent.keys"
}

@test "no ~/.ssh/*.pub and no HOMICRON_KEYS exits 2 before rsync" {
  rm "$HOME/.ssh/id_ed25519.pub"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *'~/.ssh/*.pub'* ]]
  [[ "$output" == *"HOMICRON_KEYS"* ]]
  refute_called '^rsync'
}

@test "HOMICRON_KEYS as a path ships that file" {
  printf 'ssh-ed25519 DDDD shared\n' > "$BATS_TEST_TMPDIR/shared.keys"
  printf 'HOMICRON_KEYS=%s\n' "$BATS_TEST_TMPDIR/shared.keys" >> "$REPO/hosts/box.env"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/sent.keys" "$BATS_TEST_TMPDIR/shared.keys"
  ! grep -q '^HOMICRON_KEYS=' "$BATS_TEST_TMPDIR/sent.env"
}

@test "HOMICRON_KEYS as a URL is fetched with curl and shipped" {
  make_fake curl 0 'ssh-ed25519 EEEE fetched'
  capture_sent
  HOMICRON_KEYS=https://github.com/user.keys run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^curl .*https://github.com/user.keys$'
  grep -qx 'ssh-ed25519 EEEE fetched' "$BATS_TEST_TMPDIR/sent.keys"
}

@test "a keys URL that cannot be fetched exits 2 before rsync" {
  make_fake curl 22
  HOMICRON_KEYS=https://github.com/user.keys run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"https://github.com/user.keys"* ]]
  refute_called '^rsync'
}

@test "HOMICRON_KEYS that is a directory or unreadable exits 2 with the path" {
  HOMICRON_KEYS="$BATS_TEST_TMPDIR" run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR"* ]]
  HOMICRON_KEYS="$BATS_TEST_TMPDIR/missing" run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  refute_called '^rsync'
}

@test "an empty HOMICRON_KEYS in the hosts file means the default" {
  printf 'HOMICRON_KEYS=\n' >> "$REPO/hosts/box.env"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  grep -qx 'ssh-ed25519 AAAA workstation' "$BATS_TEST_TMPDIR/sent.keys"
}

@test "a keys source with a line that is not a key exits 2 with the line number" {
  printf '<html>\n' >> "$HOME/.ssh/id_ed25519.pub"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"line 2 is not a public key"* ]]
  refute_called '^rsync'
}

@test "a keys source with no key line says so instead of naming a bad line" {
  make_fake curl 0 ''
  HOMICRON_KEYS=https://github.com/nokeys.keys run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"no key line"* ]]
  [[ "$output" != *"is not a public key"* ]]
  [[ "$output" != *"line that is not a key"* ]]
  printf '# only a comment\n' > "$BATS_TEST_TMPDIR/empty.keys"
  HOMICRON_KEYS="$BATS_TEST_TMPDIR/empty.keys" run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"no key line"* ]]
  refute_called '^rsync'
}
