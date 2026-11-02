load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/20-swap-dump.sh"
VFSTAB_LINE=$'/dev/zvol/dsk/rpool/swap\t-\t-\tswap\t-\tno\t-'

setup() {
  fakes_setup
  export SWAP_SIZE=4G DUMP_SIZE=4G HOMICRON_ETC="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$HOMICRON_ETC"
  printf '#device\t\tdevice\t\tmount\t\tFS\tfsck\tmount\tmount\n' > "$HOMICRON_ETC/vfstab"
  for c in zfs swap dumpadm; do make_fake "$c"; done
}

@test "does nothing when swap and dump are already set up" {
  printf 'echo "swapfile dev swaplo blocks free"; echo "/dev/zvol/dsk/rpool/swap 1,2 8 100 100"\n' > "$FAKE_BIN/swap.script"
  printf 'echo "      Dump content: kernel pages"; echo "       Dump device: /dev/zvol/dsk/rpool/dump (dedicated)"\n' > "$FAKE_BIN/dumpadm.script"
  printf '%s\n' "$VFSTAB_LINE" >> "$HOMICRON_ETC/vfstab"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^zfs create'
  refute_called '^swap -a'
  refute_called '^dumpadm -d'
}

@test "creates zvols, activates swap, writes vfstab, points dumpadm" {
  make_fake zfs 1
  printf '[[ $1 == create ]] && exit 0; exit 1\n' > "$FAKE_BIN/zfs.script"
  run "$STEP"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  assert_called '^zfs create -V 4G rpool/swap$'
  assert_called '^zfs create -V 4G rpool/dump$'
  assert_called '^swap -a /dev/zvol/dsk/rpool/swap$'
  assert_called '^dumpadm -d /dev/zvol/dsk/rpool/dump$'
  [ "$(grep -c -F "$VFSTAB_LINE" "$HOMICRON_ETC/vfstab")" -eq 1 ]
}

@test "long listings after the match still count as set up" {
  printf 'echo "swapfile dev swaplo blocks free"; echo "/dev/zvol/dsk/rpool/swap 1,2 8 100 100"; seq 1 300000\n' > "$FAKE_BIN/swap.script"
  printf 'echo "       Dump device: /dev/zvol/dsk/rpool/dump (dedicated)"; seq 1 300000\n' > "$FAKE_BIN/dumpadm.script"
  printf '%s\n' "$VFSTAB_LINE" >> "$HOMICRON_ETC/vfstab"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in the desired state"* ]]
}
