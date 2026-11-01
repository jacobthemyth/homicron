load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/30-pkg.sh"
PKGS='developer/build-essential developer/illumos-tools developer/versioning/git'

setup() {
  fakes_setup
  make_fake pkg
  # beadm list -H: name;uuid;active;mountpoint;space;policy;created
  make_fake beadm 0 'helios;;NR;/;1G;static;2026-10-31'
}

# beadm answers ROWS_BEFORE until a fake log line matches TRIGGER, then ROWS_AFTER.
beadm_flips_on() {
  printf 'if grep -q "%s" "$FAKE_LOG"; then printf "%%b" "%s"; else printf "%%b" "%s"; fi\n' "$1" "$3" "$2" > "$FAKE_BIN/beadm.script"
}
ONE_BE='helios;;NR;/;1G;static;x\n'
ACTIVATED_BE='helios;;N;/;1G;static;x\nhelios-1;;R;-;1G;static;x\n'

@test "nothing to do when update -n exits 4 and the packages are installed" {
  printf '[[ $1 == update && $2 == -n ]] && exit 4; exit 0\n' > "$FAKE_BIN/pkg.script"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^pkg update -v'
  refute_called '^pkg install'
}

@test "exits 10 when the update created a new boot environment" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && exit 1; exit 0\n' > "$FAKE_BIN/pkg.script"
  beadm_flips_on '^pkg update -v' "$ONE_BE" "$ACTIVATED_BE"
  run "$STEP"
  [ "$status" -eq 10 ]
  assert_called '^pkg update -v$'
  refute_called '^pkg install -v developer'
}

@test "a backup boot environment that is not activated does not request a reboot" {
  # update -n says "updates available" until update -v ran; list says "installed" once the install ran.
  printf '[[ $1 == update && $2 == -n ]] && { grep -q "^pkg update -v" "$FAKE_LOG" && exit 4 || exit 0; }; [[ $1 == list ]] && { grep -q "^pkg install -v developer" "$FAKE_LOG" && exit 0 || exit 1; }; exit 0\n' > "$FAKE_BIN/pkg.script"
  beadm_flips_on '^pkg update -v' "$ONE_BE" 'helios;;NR;/;1G;static;x\nhelios-backup-1;;-;-;1G;static;x\n'
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called "^pkg install -v $PKGS$"
}

@test "a boot environment activated by the pkg self-update requests a reboot" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && exit 1; exit 0\n' > "$FAKE_BIN/pkg.script"
  beadm_flips_on '^pkg install -v pkg:/package/pkg' "$ONE_BE" "$ACTIVATED_BE"
  run "$STEP"
  [ "$status" -eq 10 ]
  refute_called '^pkg update -v$'
}

@test "a boot environment left activated by an earlier run requests a reboot at entry" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && exit 1; exit 0\n' > "$FAKE_BIN/pkg.script"
  make_fake beadm 0 $'helios;;N;/;1G;static;x\nhelios-1;;R;-;1G;static;x'
  run "$STEP"
  [ "$status" -eq 10 ]
  refute_called '^pkg install'
  refute_called '^pkg update -v'
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
  beadm_flips_on '^pkg install -v developer' "$ONE_BE" "$ACTIVATED_BE"
  run "$STEP"
  [ "$status" -eq 10 ]
  assert_called "^pkg install -v $PKGS$"
}
