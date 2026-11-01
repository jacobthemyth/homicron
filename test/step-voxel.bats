load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/60-voxel.sh"

setup() {
  fakes_setup
  export HOMICRON_USER=jacob HOMICRON_HOME="$BATS_TEST_TMPDIR/home" VOXEL_REF=main
  SRC="$HOMICRON_HOME/jacob/src/voxel"
  # su logs the -c command and runs it, so the fake git below is exercised.
  make_fake su
  printf 'while [[ $1 != -c ]]; do shift; done; printf "%%s\\n" "$2" >> "$FAKE_LOG.su"; HOME="$HOMICRON_HOME/$HOMICRON_USER" bash -c "$2"\n' > "$FAKE_BIN/su.script"
  make_fake git
  printf 'case "$1" in rev-parse) echo abc123 ;; clone) mkdir -p "${*: -1}/.git" ;; esac; exit 0\n' > "$FAKE_BIN/git.script"
  make_fake cargo
}

make_checkout() {
  mkdir -p "$SRC/.git" "$SRC/target/release"
  touch -t 202601010000 "$SRC/.git/HEAD"
}

@test "does nothing when the checkout is current and the binary is newer" {
  make_checkout
  touch -t 202601020000 "$SRC/target/release/voxel"
  run "$STEP"
  [ "$status" -eq 0 ]
  ! grep -q 'cargo build' "$FAKE_LOG.su"
  ! grep -q 'git clone' "$FAKE_LOG.su"
}

@test "rebuilds when the binary is older than the checkout" {
  make_checkout
  touch -t 202512310000 "$SRC/target/release/voxel"
  run "$STEP"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  grep -q 'git checkout --detach' "$FAKE_LOG.su"
  grep -q 'cargo build --release' "$FAKE_LOG.su"
}

@test "clones when there is no checkout" {
  run "$STEP"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  grep -q "git clone https://github.com/oxidecomputer/voxel $SRC" "$FAKE_LOG.su"
  grep -q 'cargo build --release' "$FAKE_LOG.su"
}
