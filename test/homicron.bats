load helpers/fakes

BIN="$BATS_TEST_DIRNAME/../bin/homicron"

setup() {
  fakes_setup
  export REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/hosts" "$REPO/host" "$REPO/bin"
  if [[ -f $BIN ]]; then cp "$BIN" "$REPO/bin/homicron"; fi
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  printf 'ssh-ed25519 AAAAC3one workstation\n' > "$HOME/.ssh/id_ed25519.pub"
  unset HOMICRON_KEYS
  printf 'HOMICRON_USER=vmuser\nHOMICRON_UID=501\nHOMICRON_PORT=2222\n' > "$REPO/hosts/box.env"
  printf '#!/bin/bash\n' > "$REPO/host/10-a.sh"
  printf '#!/bin/bash\n' > "$REPO/host/20-b.sh"
  make_fake rsync
  make_fake ssh
  # The reboot wait reads the clock through date +%s and waits with sleep.
  # Both are faked: sleep advances a counter file, date prints it, so the
  # tests never wait and every timing is deterministic.
  export CLOCK="$BATS_TEST_TMPDIR/clock"
  printf '1000000\n' > "$CLOCK"
  make_fake sleep
  printf 'printf "%%s\\n" "$(( $(cat "$CLOCK") + ${1%%.*} ))" > "$CLOCK"; exit 0\n' > "$FAKE_BIN/sleep.script"
  make_fake date
  printf 'cat "$CLOCK"\n' > "$FAKE_BIN/date.script"
  export HOMICRON_POLL_SECONDS=5 HOMICRON_REBOOT_TIMEOUT=30 HOMICRON_REBOOT_GRACE=10
  unset HOMICRON_ADDR
}

# A fake box behind ssh: the service state from $STATE ("<state> <stime>"),
# the apply.log line count from $LOG_LINES, the last run header line number
# from $HEADER_LINE, start-apply.sh's line from $START, and watch-apply.sh's
# stream and exit status from $STREAM and $WATCH_EXIT. The Nth watch call
# prefers $STREAM.N and $WATCH_EXIT.N when they exist.
box_fake() {
  export STATE="$BATS_TEST_TMPDIR/state" LOG_LINES="$BATS_TEST_TMPDIR/loglines" HEADER_LINE="$BATS_TEST_TMPDIR/header"
  export START="$BATS_TEST_TMPDIR/start" STREAM="$BATS_TEST_TMPDIR/stream" WATCH_EXIT="$BATS_TEST_TMPDIR/watchexit"
  printf 'disabled -\n' > "$STATE"; printf '0\n' > "$LOG_LINES"; : > "$HEADER_LINE"
  printf 'enabled and started\n' > "$START"; : > "$STREAM"; printf '0\n' > "$WATCH_EXIT"
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *svcs*) cat "$STATE"; exit 0 ;;
  *"wc -l"*) cat "$LOG_LINES"; exit 0 ;;
  *grep*) cat "$HEADER_LINE"; exit 0 ;;
  *start-apply.sh*) cat "$START"; exit 0 ;;
  *watch-apply.sh*)
    n=$(grep -c 'watch-apply.sh' "$FAKE_LOG")
    if [[ -f $STREAM.$n ]]; then cat "$STREAM.$n"; else cat "$STREAM"; fi
    if [[ -f $WATCH_EXIT.$n ]]; then exit "$(cat "$WATCH_EXIT.$n")"; else exit "$(cat "$WATCH_EXIT")"; fi ;;
  *kstat*) printf 'unix:0:system_misc:boot_time\t%s\n' "$(cat "$BATS_TEST_TMPDIR/boot" 2>/dev/null || echo 1000)"; exit 0 ;;
  *) exit 0 ;;
esac
EOS
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

@test "an unknown variable in the hosts file exits 2 with the line number before rsync" {
  printf 'HOMICRON_USER=vmuser\nHOMICRON_UID=501\nVOXEL_SLED=8\n' > "$REPO/hosts/typo.env"
  run "$REPO/bin/homicron" apply typo
  [ "$status" -eq 2 ]
  [[ "$output" == *"typo.env line 3"* ]]
  [[ "$output" == *"VOXEL_SLED"* ]]
  refute_called '^rsync'
}

@test "ships, starts the service, streams the log, and says complete" {
  box_fake
  printf 'line one\napply complete\n' > "$STREAM"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^rsync .* root@box.local:/opt/homicron/$'
  assert_called 'root@box.local /opt/homicron/start-apply.sh$'
  assert_called 'root@box.local /opt/homicron/watch-apply.sh 0 7200$'
  [[ "$output" == *$'enabled and started\nline one\napply complete' ]]
  [[ "${lines[-1]}" == "apply complete" ]]
  refute_called 'run-step'
  refute_called 'pfexec'
}

@test "the watch starts after the lines an earlier run left in the log" {
  box_fake
  printf '42\n' > "$LOG_LINES"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called 'watch-apply.sh 42 7200$'
}

@test "a running apply is attached from its run header, with nothing shipped" {
  box_fake
  printf 'offline* 10:00:00\n' > "$STATE"
  printf '7\n' > "$HEADER_LINE"
  printf 'rest\napply complete\n' > "$STREAM"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  refute_called '^rsync'
  refute_called 'start-apply.sh'
  assert_called 'watch-apply.sh 6 7200$'
  [[ "$output" == *"already running on the box since 10:00:00"* ]]
}

@test "a reboot line then 255 waits for a new boot time and reconnects with the line count" {
  box_fake
  printf 'x\nrebooting for 30-pkg.sh\n' > "$STREAM.1"; printf '255\n' > "$WATCH_EXIT.1"
  printf 'apply complete\n' > "$STREAM.2"; printf '0\n' > "$WATCH_EXIT.2"
  # the boot time changes after the first kstat read
  printf 'n=$(grep -c kstat "$FAKE_LOG"); if (( n <= 1 )); then echo 1000; else echo 1001; fi > "$BATS_TEST_TMPDIR/boot"\n' > "$FAKE_BIN/boot.sh"
  sed -i '' 's|\*kstat\*) |*kstat*) bash "$FAKE_BIN/boot.sh"; |' "$FAKE_BIN/ssh.script"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  refute_called 'root@box.local reboot$'
  assert_called 'watch-apply.sh 0 7200$'
  assert_called 'watch-apply.sh 2 7200$'
  [[ "$output" == *"waiting for the box to come back"* ]]
  [[ "${lines[-1]}" == "apply complete" ]]
}

@test "a reboot line then 255, without kstat, waits for ssh to return" {
  box_fake
  printf 'rebooting for 30-pkg.sh\n' > "$STREAM.1"; printf '255\n' > "$WATCH_EXIT.1"
  printf 'apply complete\n' > "$STREAM.2"; printf '0\n' > "$WATCH_EXIT.2"
  sed -i '' 's|\*kstat\*) .*|*kstat*) exit 1 ;;|' "$FAKE_BIN/ssh.script"
  sed -i '' 's|\*) exit 0 ;;|*root@box.local\\ true) t=$(grep -c "true$" "$FAKE_LOG"); if (( t <= 2 )); then exit 255; else exit 0; fi ;;\n  *) exit 0 ;;|' "$FAKE_BIN/ssh.script"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [ "$(fake_calls | grep -c 'true$')" -eq 3 ]
  assert_called 'watch-apply.sh 1 7200$'
}

@test "a box that never comes back after the reboot line is reported with the timeout" {
  box_fake
  printf 'rebooting for 30-pkg.sh\n' > "$STREAM"; printf '255\n' > "$WATCH_EXIT"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local after 30s; the apply continues on the box, rejoin with homicron apply box"* ]]
  # 30 s of timeout at 5 s a poll: six waits, then the deadline
  [ "$(fake_calls | grep -c '^sleep 5$')" -eq 6 ]
}

@test "255 without a reboot line waits for the box and reconnects at the offset" {
  box_fake
  printf 'x\ny\n' > "$STREAM.1"; printf '255\n' > "$WATCH_EXIT.1"
  printf 'apply complete\n' > "$STREAM.2"; printf '0\n' > "$WATCH_EXIT.2"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [[ "$output" == *"connection lost; waiting for the box"* ]]
  assert_called 'watch-apply.sh 2 7200$'
  [[ "${lines[-1]}" == "apply complete" ]]
}

@test "a box that never answers after a dropped connection is reported with the rejoin command" {
  box_fake
  printf 'x\n' > "$STREAM"; printf '255\n' > "$WATCH_EXIT"
  sed -i '' 's|\*) exit 0 ;;|*root@box.local\\ true) exit 255 ;;\n  *) exit 0 ;;|' "$FAKE_BIN/ssh.script"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local after 30s; the apply continues on the box, rejoin with homicron apply box"* ]]
  [ "$(fake_calls | grep -c '^sleep 5$')" -eq 6 ]
}

@test "an unreachable box is reported at the first ssh, before rsync" {
  make_fake ssh 255
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local"* ]]
  [[ "$output" == *"ssh root@box.local"* ]]
  refute_called '^rsync'
}

@test "rsync failing to connect reports unreachable and never starts the service" {
  box_fake
  make_fake rsync 255
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local"* ]]
  refute_called 'start-apply.sh'
}

@test "a service that does not exist yet counts as not running" {
  box_fake
  sed -i '' 's|\*svcs\*) .*|*svcs*) exit 1 ;;|' "$FAKE_BIN/ssh.script"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^rsync'
  assert_called 'start-apply.sh$'
}

@test "a failed step exits with its status and names it" {
  box_fake
  printf 'some output\nstep 10-a.sh failed with status 3\n' > "$STREAM"; printf '1\n' > "$WATCH_EXIT"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 3 ]
  [[ "${lines[-1]}" == "homicron: step 10-a.sh failed with status 3" ]]
  refute_called 'cat /var/log'
}

@test "a watch timeout says how to rejoin" {
  box_fake
  printf '4\n' > "$WATCH_EXIT"
  HOMICRON_APPLY_TIMEOUT=30 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  assert_called 'watch-apply.sh 0 30$'
  [[ "$output" == *"still running after 30s; rejoin with homicron apply box"* ]]
}

@test "an unexpected watch exit names the status and the log" {
  box_fake
  printf 'service is disabled\n' > "$STREAM"; printf '3\n' > "$WATCH_EXIT"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"service is disabled"* ]]
  [[ "$output" == *"/var/homicron/apply.log"* ]]
}

@test "start-apply failing stops with its output" {
  box_fake
  sed -i '' 's|\*start-apply.sh\*) .*|*start-apply.sh*) echo "bad manifest"; exit 2 ;;|' "$FAKE_BIN/ssh.script"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad manifest"* ]]
  refute_called 'watch-apply.sh'
}

@test "start-apply reporting a running apply attaches from the run header" {
  box_fake
  printf 'an apply is already running on the box\n' > "$START"
  printf '7\n' > "$HEADER_LINE"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called 'watch-apply.sh 6 7200$'
}

@test "attaching with no run header in the log starts after the existing lines" {
  box_fake
  printf 'offline* 10:00:00\n' > "$STATE"
  printf '42\n' > "$LOG_LINES"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called 'watch-apply.sh 42 7200$'
}

@test "a reboot line then 255, without kstat, does not take a box that has not gone down yet for a rebooted one" {
  box_fake
  printf 'rebooting for 30-pkg.sh\n' > "$STREAM.1"; printf '255\n' > "$WATCH_EXIT.1"
  printf 'apply complete\n' > "$STREAM.2"; printf '0\n' > "$WATCH_EXIT.2"
  sed -i '' 's|\*kstat\*) .*|*kstat*) exit 1 ;;|' "$FAKE_BIN/ssh.script"
  # still up on the first poll, down for two, then back
  sed -i '' 's|\*) exit 0 ;;|*root@box.local\\ true) t=$(grep -c "true$" "$FAKE_LOG"); if (( t == 2 \|\| t == 3 )); then exit 255; else exit 0; fi ;;\n  *) exit 0 ;;|' "$FAKE_BIN/ssh.script"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [ "$(fake_calls | grep -c 'true$')" -eq 4 ]
  [ "$(fake_calls | grep -c 'watch-apply.sh')" -eq 2 ]
}

@test "ssh subcommand uses the user and port, without keepalives" {
  run "$REPO/bin/homicron" ssh box
  assert_called '^ssh -p 2222 .*vmuser@box.local$'
  refute_called 'ServerAlive.*vmuser@box.local$'
}

@test "every ssh and the rsync transport carry keepalives" {
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^ssh -p 2222 -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@box.local /opt/homicron/watch-apply.sh 0 7200$'
  assert_called '^rsync .* -e ssh -p 2222 -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 .*host.env$'
}

@test "an rsync failure that is not 255 is reported as rsync, not as unreachable" {
  make_fake rsync 127
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"rsync failed with status 127"* ]]
  [[ "$output" != *"cannot reach"* ]]
  refute_called 'start-apply.sh'
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

@test "ships the rack variables with their defaults" {
  capture_sent
  MGMT_LINKS=igb1 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  grep -qx 'VOXEL_EXTERNAL_MODE=lan' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_EXTERNAL_UPLINK=' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_CP_IMAGE=' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'MGMT_LINKS=igb1' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_RACK=yes' "$BATS_TEST_TMPDIR/sent.env"
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

@test "by default the shipped keys are every ~/.ssh/*.pub, each ending in a newline, certificates skipped" {
  printf 'ssh-rsa AAAAB3two second' > "$HOME/.ssh/id_rsa.pub"
  printf 'ssh-ed25519-cert-v01@openssh.com AAAAcert cert\n' > "$HOME/.ssh/id_ed25519-cert.pub"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/sent.keys" | tr -d ' ')" -eq 2 ]
  grep -qx 'ssh-ed25519 AAAAC3one workstation' "$BATS_TEST_TMPDIR/sent.keys"
  grep -qx 'ssh-rsa AAAAB3two second' "$BATS_TEST_TMPDIR/sent.keys"
  ! grep -q AAAAcert "$BATS_TEST_TMPDIR/sent.keys"
  [[ "$output" == *'shipping 2 keys from ~/.ssh/*.pub'* ]]
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
  printf 'ssh-ed25519 AAAAshared shared\n' > "$BATS_TEST_TMPDIR/shared.keys"
  printf 'HOMICRON_KEYS=%s\n' "$BATS_TEST_TMPDIR/shared.keys" >> "$REPO/hosts/box.env"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/sent.keys" "$BATS_TEST_TMPDIR/shared.keys"
  ! grep -q '^HOMICRON_KEYS=' "$BATS_TEST_TMPDIR/sent.env"
  [[ "$output" == *"shipping 1 key from $BATS_TEST_TMPDIR/shared.keys"* ]]
}

@test "HOMICRON_KEYS as a URL is fetched with curl and shipped" {
  make_fake curl 0 'ssh-ed25519 AAAAfetched fetched'
  capture_sent
  HOMICRON_KEYS=https://github.com/user.keys run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^curl .*https://github.com/user.keys$'
  grep -qx 'ssh-ed25519 AAAAfetched fetched' "$BATS_TEST_TMPDIR/sent.keys"
  [[ "$output" == *'shipping 1 key from https://github.com/user.keys'* ]]
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
  grep -qx 'ssh-ed25519 AAAAC3one workstation' "$BATS_TEST_TMPDIR/sent.keys"
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

@test "a relative HOMICRON_KEYS path resolves from the current directory" {
  printf 'ssh-ed25519 AAAArel relative\n' > "$BATS_TEST_TMPDIR/rel.keys"
  capture_sent
  cd "$BATS_TEST_TMPDIR"
  HOMICRON_KEYS=rel.keys run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/sent.keys" "$BATS_TEST_TMPDIR/rel.keys"
}

@test "a line with a key type but no real blob is not a key" {
  printf 'Use ssh-keygen to make a key\nssh-rsa not=base64 x\n' > "$BATS_TEST_TMPDIR/prose.keys"
  HOMICRON_KEYS="$BATS_TEST_TMPDIR/prose.keys" run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"line 1 is not a public key"* ]]
  [[ "$output" == *"line 2 is not a public key"* ]]
  refute_called '^rsync'
}
