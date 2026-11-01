load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/30-pkg.sh"
PKGS='developer/build-essential developer/illumos-tools developer/versioning/git'

setup() {
  fakes_setup
  make_fake pkg
  make_fake beadm 0 'helios'
}

@test "nothing to do when update -n exits 4 and the packages are installed" {
  printf '[[ $1 == update && $2 == -n ]] && exit 4; exit 0\n' > "$FAKE_BIN/pkg.script"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^pkg update -v'
  refute_called '^pkg install'
}

@test "exits 10 when the update created a new boot environment" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && exit 1; exit 0\n' > "$FAKE_BIN/pkg.script"
  printf 'n=$(grep -c "^beadm" "$FAKE_LOG"); if [[ $n -ge 2 ]]; then printf "helios\\nhelios-1\\n"; else echo helios; fi\n' > "$FAKE_BIN/beadm.script"
  run "$STEP"
  [ "$status" -eq 10 ]
  assert_called '^pkg update -v$'
  refute_called '^pkg install -v developer'
}

@test "update exiting 4 proceeds to install the packages" {
  printf '[[ $1 == update ]] && exit 4; [[ $1 == list ]] && { n=$(grep -c "^pkg install -v developer" "$FAKE_LOG"); [[ $n -ge 1 ]] && exit 0 || exit 1; }; exit 0\n' > "$FAKE_BIN/pkg.script"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called "^pkg install -v $PKGS$"
}

@test "update failing with 1 fails the step" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == install ]] && exit 4; [[ $1 == update ]] && exit 1; exit 1\n' > "$FAKE_BIN/pkg.script"
  run "$STEP"
  [ "$status" -eq 1 ]
  refute_called '^pkg install -v developer'
}

@test "updates pkg(7) itself before running pkg update" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && exit 1; [[ $1 == install && $3 == pkg:/package/pkg ]] && exit 4; exit 0\n' > "$FAKE_BIN/pkg.script"
  run "$STEP"
  assert_called '^pkg install -v pkg:/package/pkg$'
  first_install=$(grep -n '^pkg install -v pkg:/package/pkg$' "$FAKE_LOG" | head -1 | cut -d: -f1)
  first_update=$(grep -n '^pkg update -v$' "$FAKE_LOG" | head -1 | cut -d: -f1)
  [ "$first_install" -lt "$first_update" ]
}

@test "exits 10 when installing the developer packages created a new boot environment" {
  printf '[[ $1 == update ]] && exit 4; [[ $1 == list ]] && exit 1; exit 0\n' > "$FAKE_BIN/pkg.script"
  printf 'if grep -q "^pkg install -v developer" "$FAKE_LOG"; then printf "helios\\nhelios-1\\n"; else echo helios; fi\n' > "$FAKE_BIN/beadm.script"
  run "$STEP"
  [ "$status" -eq 10 ]
  assert_called "^pkg install -v $PKGS$"
}
