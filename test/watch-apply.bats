load helpers/fakes

setup() {
  fakes_setup
  export HOMICRON_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$HOMICRON_LOG_DIR"
  WATCH="$BATS_TEST_TMPDIR/watch-apply.sh"
  if [[ -f "$BATS_TEST_DIRNAME/../host/watch-apply.sh" ]]; then cp "$BATS_TEST_DIRNAME/../host/watch-apply.sh" "$WATCH"; fi
  make_fake sleep
  make_fake svcs 0 online
  export LOG="$HOMICRON_LOG_DIR/apply.log"
  printf 'one\ntwo\nthree\n' > "$LOG"
}

@test "prints the lines after the offset and exits 0 when online" {
  run "$WATCH" 1 60
  [ "$status" -eq 0 ]
  [[ "$output" == $'two\nthree' ]]
}

@test "maintenance exits 1 after printing the rest" {
  make_fake svcs 0 maintenance
  run "$WATCH" 3 60
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "keeps polling while the method runs, then prints what arrived" {
  printf 'n=$(grep -c "^svcs" "$FAKE_LOG"); (( n == 2 )) && echo four >> "$LOG"; if (( n < 3 )); then echo "offline*"; else echo online; fi; exit 0\n' > "$FAKE_BIN/svcs.script"
  run "$WATCH" 3 60
  [ "$status" -eq 0 ]
  [[ "$output" == "four" ]]
  [ "$(fake_calls | grep -c '^sleep 1$')" -eq 2 ]
}

@test "a missing log or an offset past the end prints nothing and still settles" {
  rm "$LOG"
  run "$WATCH" 0 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'one\n' > "$LOG"
  run "$WATCH" 5 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "another settled state exits 3 and names it" {
  make_fake svcs 0 disabled
  run "$WATCH" 3 60
  [ "$status" -eq 3 ]
  [[ "$output" == "service is disabled" ]]
}

@test "a method still running after max-seconds exits 4" {
  make_fake svcs 0 'offline*'
  run "$WATCH" 3 2
  [ "$status" -eq 4 ]
  [ "$(fake_calls | grep -c '^sleep 1$')" -eq 2 ]
}
