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
  # Like real git, rev-parse without --verify echoes an unresolvable name
  # to stdout before the result; with --verify -q it prints one line.
  printf 'case "$1" in rev-parse) if [[ $* == *"^{commit}"* && $* != *--verify* ]]; then echo "origin/${*: -1}"; fi; echo abc123 ;; clone) mkdir -p "${*: -1}/.git" ;; esac; exit 0\n' > "$FAKE_BIN/git.script"
  make_fake cargo
}

make_checkout() {
  mkdir -p "$SRC/.git" "$SRC/target/release"
  : > "$SRC/.git/HEAD"
  : > "$SRC/target/release/voxel"
  chmod +x "$SRC/target/release/voxel"
}

@test "does nothing when the binary was built from the current commit" {
  make_checkout
  echo abc123 > "$SRC/target/.homicron-built"
  run "$STEP"
  [ "$status" -eq 0 ]
  ! grep -q 'cargo build' "$FAKE_LOG.su"
  ! grep -q 'git clone' "$FAKE_LOG.su"
}

@test "rebuilds when the binary came from another commit, then records the commit" {
  make_checkout
  echo 000000 > "$SRC/target/.homicron-built"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -q 'git checkout --detach abc123' "$FAKE_LOG.su"
  grep -q 'cargo build --release' "$FAKE_LOG.su"
  [ "$(cat "$SRC/target/.homicron-built")" = abc123 ]
  [ "$(grep -c 'git fetch' "$FAKE_LOG.su")" -eq 2 ]
}

@test "a docs-only upstream commit does not wedge the step" {
  # cargo build is a no-op (binary unchanged) but HEAD moved; the marker, not mtime, decides.
  make_checkout
  echo 000000 > "$SRC/target/.homicron-built"
  run "$STEP"
  [ "$status" -eq 0 ]
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'cargo build' "$FAKE_LOG.su")" -eq 1 ]
}

@test "clones when there is no checkout" {
  printf 'case "$1" in rev-parse) echo abc123 ;; clone) mkdir -p "${*: -1}/.git" "${*: -1}/target/release"; : > "${*: -1}/target/release/voxel"; chmod +x "${*: -1}/target/release/voxel" ;; esac; exit 0\n' > "$FAKE_BIN/git.script"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -q "git clone https://github.com/oxidecomputer/voxel $SRC" "$FAKE_LOG.su"
  grep -q 'cargo build --release' "$FAKE_LOG.su"
  [ "$(grep -c 'git fetch' "$FAKE_LOG.su")" -eq 1 ]
}

@test "a tag ref converges on the first run" {
  make_checkout
  echo abc123 > "$SRC/target/.homicron-built"
  VOXEL_REF=v0.9 run "$STEP"
  [ "$status" -eq 0 ]
  ! grep -q 'cargo build' "$FAKE_LOG.su"
}

@test "a ref that resolves to nothing fails before checkout or build" {
  make_checkout
  printf 'case "$1" in rev-parse) [[ $* == *--verify* ]] && exit 1; echo abc123 ;; esac; exit 0\n' > "$FAKE_BIN/git.script"
  run "$STEP"
  [ "$status" -ne 0 ]
  ! grep -q 'git checkout' "$FAKE_LOG.su"
  ! grep -q 'cargo build' "$FAKE_LOG.su"
}
