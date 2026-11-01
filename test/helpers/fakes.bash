#!/bin/bash
#
# Fake external commands for bats tests. Source with `load helpers/fakes`.
#
# fakes_setup            create $FAKE_BIN and $FAKE_LOG, prepend $FAKE_BIN to PATH
# make_fake NAME [EXIT] [STDOUT]
#                        write $FAKE_BIN/NAME; it appends "NAME ARGS..." to $FAKE_LOG,
#                        then sources $FAKE_BIN/NAME.script if present (with "$@"),
#                        else prints STDOUT and exits EXIT
# fake_calls             print the log
# assert_called REGEX    fail unless a log line matches
# refute_called REGEX    fail if a log line matches

fakes_setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/fakebin"
  FAKE_LOG="$BATS_TEST_TMPDIR/fakes.log"
  mkdir -p "$FAKE_BIN"
  : > "$FAKE_LOG"
  export FAKE_BIN FAKE_LOG
  PATH="$FAKE_BIN:$PATH"
  export PATH
}

make_fake() {
  local name="$1" exit_code="${2:-0}" stdout="${3-}"
  cat > "$FAKE_BIN/$name" <<SCRIPT
#!/bin/bash
printf '%s\\n' "$name \$*" >> "\$FAKE_LOG"
if [[ -f "\$FAKE_BIN/$name.script" ]]; then
  source "\$FAKE_BIN/$name.script"
  exit \$?
fi
if [[ -n "$stdout" ]]; then printf '%s\\n' "$stdout"; fi
exit $exit_code
SCRIPT
  chmod +x "$FAKE_BIN/$name"
}

fake_calls() {
  cat "$FAKE_LOG"
}

assert_called() {
  if ! grep -E -q -- "$1" "$FAKE_LOG"; then
    echo "expected a call matching: $1"
    echo "calls were:"
    cat "$FAKE_LOG"
    return 1
  fi
}

refute_called() {
  if grep -E -q -- "$1" "$FAKE_LOG"; then
    echo "unexpected call matching: $1"
    echo "calls were:"
    cat "$FAKE_LOG"
    return 1
  fi
}
