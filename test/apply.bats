load helpers/fakes

setup() {
  fakes_setup
  export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt" HOMICRON_LOG_DIR="$BATS_TEST_TMPDIR/log" HOMICRON_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$HOMICRON_DIR" "$HOMICRON_STATE_DIR"
  if [[ -f "$BATS_TEST_DIRNAME/../host/apply.sh" ]]; then cp "$BATS_TEST_DIRNAME/../host/apply.sh" "$HOMICRON_DIR/"; fi
  printf 'HOMICRON_USER=vmuser\nSWAP_SIZE=4G\n' > "$HOMICRON_DIR/host.env"
  printf '#!/bin/bash\necho "user=$HOMICRON_USER swap=$SWAP_SIZE"; exit 0\n' > "$HOMICRON_DIR/10-a.sh"
  printf '#!/bin/bash\necho b; exit 0\n' > "$HOMICRON_DIR/20-b.sh"
  make_fake kstat 0 $'unix:0:system_misc:boot_time\t1000'
  make_fake reboot
  make_fake sleep
  printf '1000\n' > "$HOMICRON_STATE_DIR/apply-requested"
  LOG="$HOMICRON_STATE_DIR/apply.log"
}

@test "no marker: exits 0 and runs nothing" {
  rm "$HOMICRON_STATE_DIR/apply-requested"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "runs the steps in order with the environment, logs each, deletes the marker, says complete" {
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 0 ]
  grep -q '^=== run ' "$LOG"
  ! grep -q 'resumed' "$LOG"
  [[ "$(grep '^==> ' "$LOG" | tr '\n' ' ')" == "==> 10-a.sh ==> 20-b.sh " ]]
  grep -q 'user=vmuser swap=4G' "$LOG"
  grep -q 'user=vmuser swap=4G' "$HOMICRON_LOG_DIR/10-a.sh.log"
  grep -q '^+ echo' "$HOMICRON_LOG_DIR/10-a.sh.log"
  [[ "$(tail -1 "$LOG")" == "apply complete" ]]
  [ ! -e "$HOMICRON_STATE_DIR/apply-requested" ]
}

@test "a failing step logs the status, exits 95 (SMF fatal), keeps the marker, runs no later step" {
  printf '#!/bin/bash\nexit 3\n' > "$HOMICRON_DIR/10-a.sh"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 95 ]
  [[ "$(tail -1 "$LOG")" == "step 10-a.sh failed with status 3" ]]
  ! grep -q '^==> 20-b.sh' "$LOG"
  [ -e "$HOMICRON_STATE_DIR/apply-requested" ]
}

@test "exit 10 logs the reboot, records the step in the marker, reboots once, runs no later step" {
  printf '#!/bin/bash\nexit 10\n' > "$HOMICRON_DIR/10-a.sh"
  run "$HOMICRON_DIR/apply.sh"
  [[ "$(tail -1 "$LOG")" == "rebooting for 10-a.sh" ]]
  [ "$(fake_calls | grep -Ec '^reboot ?$')" -eq 1 ]
  # the watcher polls once a second; give it time to read the announcement
  [[ "$(fake_calls | grep -E '^(sleep|reboot)' | tr '\n' ' ')" == "sleep 3 reboot  " ]]
  [[ "$(cat "$HOMICRON_STATE_DIR/apply-requested")" == "1000 10-a.sh" ]]
  ! grep -q '^==> 20-b.sh' "$LOG"
}

@test "a marker from an earlier boot gives the resumed header" {
  printf '900\n' > "$HOMICRON_STATE_DIR/apply-requested"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 0 ]
  grep -q '^=== run .* (resumed after reboot)$' "$LOG"
}

@test "a step that asks for a second reboot in a row fails instead of rebooting" {
  printf '900 10-a.sh\n' > "$HOMICRON_STATE_DIR/apply-requested"
  printf '#!/bin/bash\nexit 10\n' > "$HOMICRON_DIR/10-a.sh"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 95 ]
  refute_called '^reboot ?$'
  [[ "$(tail -1 "$LOG")" == "step 10-a.sh failed with status 10 (asked for a second reboot)" ]]
}

@test "a missing host.env logs and exits 96 (SMF config error)" {
  rm "$HOMICRON_DIR/host.env"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 96 ]
  grep -q 'host.env' "$LOG"
}
