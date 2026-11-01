load helpers/fakes

setup() {
  fakes_setup
  export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt" HOMICRON_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$HOMICRON_DIR"
  if [[ -f "$BATS_TEST_DIRNAME/../host/run-step.sh" ]]; then cp "$BATS_TEST_DIRNAME/../host/run-step.sh" "$HOMICRON_DIR/"; fi
  printf 'HOMICRON_USER=jacob\nSWAP_SIZE=4G\n' > "$HOMICRON_DIR/host.env"
  printf '#!/bin/bash\necho "user=$HOMICRON_USER swap=$SWAP_SIZE"; exit 10\n' > "$HOMICRON_DIR/99-x.sh"
}

@test "exports env, logs output, passes status through" {
  run "$HOMICRON_DIR/run-step.sh" 99-x.sh
  [ "$status" -eq 10 ]
  [[ "$output" == *"user=jacob swap=4G"* ]]
  grep -q 'user=jacob swap=4G' "$HOMICRON_LOG_DIR/99-x.sh.log"
}
