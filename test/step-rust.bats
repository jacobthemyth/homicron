load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/40-rust.sh"

setup() {
  fakes_setup
  export HOMICRON_USER=vmuser
  make_fake su
  printf 'printf "%%s\\n" "$*" >> "$FAKE_LOG.su"; exit "${SU_EXIT:-0}"\n' > "$FAKE_BIN/su.script"
}

@test "does nothing when cargo already runs for the user" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'sh.rustup.rs' "$FAKE_LOG.su")" -eq 0 ]
}

@test "installs rustup as the user when cargo is missing" {
  printf 'c="$*"; printf "%%s\\n" "$c" >> "$FAKE_LOG.su"; if [[ $c == *rustup.rs* ]]; then exit 0; fi; n=$(grep -c rustup.rs "$FAKE_LOG.su"); if [[ $n -ge 1 ]]; then exit 0; fi; exit 1\n' > "$FAKE_BIN/su.script"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^su - vmuser -c '
  grep -q 'sh.rustup.rs' "$FAKE_LOG.su"
  grep -q -- '-y --profile minimal' "$FAKE_LOG.su"
}
