load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/65-viona-workaround.sh"
LINE='set viona:viona_feat_disable_mask=0x20000000'
VALIDATED=a6ad27b230e2541bd7ca2f12ee7c08dd7a3d2174

setup() {
  fakes_setup
  export HOMICRON_USER=vmuser VOXEL_REF=main
  export HOMICRON_ETC="$BATS_TEST_TMPDIR/etc" HOMICRON_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOMICRON_ETC"
  printf '* existing tunables\nset zfs:zfs_arc_max=0x100000000\n' > "$HOMICRON_ETC/system"
  # The fake mdb keeps the live mask in a file: -k prints it, -kw sets it.
  export MASK_FILE="$BATS_TEST_TMPDIR/mask"
  printf '0\n' > "$MASK_FILE"
  make_fake mdb
  cat > "$FAKE_BIN/mdb.script" <<'EOS'
in=$(cat)
if [[ ! -f $MASK_FILE ]]; then echo "mdb: failed to dereference symbol: unknown symbol name" >&2; exit 1; fi
if [[ $* == *-kw* ]]; then v=${in##*/Z }; printf '%s\n' "${v#0x}" > "$MASK_FILE"; exit 0; fi
printf 'viona_feat_disable_mask:\nviona_feat_disable_mask:        %s\n' "$(cat "$MASK_FILE")"
EOS
  # modinfo lists viona only while the module is loaded; the mask file stands
  # in for that, and the fake modload creates it with the compiled default.
  make_fake modinfo
  printf '[[ -f $MASK_FILE ]] && echo "184 fffffffff4184000 97e8 289 1 viona (Virtio Network Accelerator)"; exit 0\n' > "$FAKE_BIN/modinfo.script"
  make_fake modload
  printf 'printf "0\\n" > "$MASK_FILE"; exit 0\n' > "$FAKE_BIN/modload.script"
  # The fake su answers git rev-parse with the commit in $HEAD_FILE.
  export HEAD_FILE="$BATS_TEST_TMPDIR/head"
  printf '%s\n' "$VALIDATED" > "$HEAD_FILE"
  mkdir -p "$HOMICRON_HOME/vmuser/src/voxel/.git"
  make_fake su
  printf 'c="$*"; printf "%%s\\n" "$c" >> "$FAKE_LOG.su"; if [[ $c == *rev-parse* ]]; then cat "$HEAD_FILE"; fi; exit 0\n' > "$FAKE_BIN/su.script"
}

@test "appends the line to /etc/system and sets the live mask" {
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qxF "$LINE" "$HOMICRON_ETC/system"
  grep -qx 'set zfs:zfs_arc_max=0x100000000' "$HOMICRON_ETC/system"
  [ "$(cat "$MASK_FILE")" = 20000000 ]
  assert_called '^mdb -kw'
  [[ "$output" != *warning* ]]
}

@test "does nothing when the line and the live mask are already in place" {
  printf '%s\n' "$LINE" >> "$HOMICRON_ETC/system"
  printf '20000000\n' > "$MASK_FILE"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in the desired state"* ]]
  refute_called '^mdb -kw'
  [ "$(grep -cxF "$LINE" "$HOMICRON_ETC/system")" -eq 1 ]
}

@test "sets only the live mask when the line is present but the kernel value is not" {
  printf '%s\n' "$LINE" >> "$HOMICRON_ETC/system"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^mdb -kw'
  [ "$(grep -cxF "$LINE" "$HOMICRON_ETC/system")" -eq 1 ]
}

@test "warns when the voxel checkout is not at the validated commit" {
  printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$HEAD_FILE"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *warning* ]]
  [[ "$output" == *"VOXEL_REF=main"* ]]
  [[ "$output" == *abcdef0123456789abcdef0123456789abcdef01* ]]
  [[ "$output" == *"falcon/issues/383"* ]]
  [[ "$output" == *"$LINE"* ]]
  grep -qxF "$LINE" "$HOMICRON_ETC/system"
}

@test "no checkout yet means no warning and no failure" {
  rm -rf "$HOMICRON_HOME/vmuser/src/voxel"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" != *warning* ]]
  grep -qxF "$LINE" "$HOMICRON_ETC/system"
}

@test "a /etc/system without a trailing newline does not get a fused line" {
  printf 'set zfs:zfs_arc_max=0x100000000' > "$HOMICRON_ETC/system"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx 'set zfs:zfs_arc_max=0x100000000' "$HOMICRON_ETC/system"
  grep -qxF "$LINE" "$HOMICRON_ETC/system"
}

@test "an unloaded viona module is loaded with modload so the mask can be set live" {
  rm -f "$MASK_FILE"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qxF "$LINE" "$HOMICRON_ETC/system"
  assert_called '^modload /usr/kernel/drv/amd64/viona$'
  assert_called '^mdb -kw'
  [ "$(cat "$MASK_FILE")" = 20000000 ]
}

@test "a loaded module is not loaded again" {
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^modload'
}
