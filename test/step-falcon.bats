load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/50-falcon.sh"

setup() {
  fakes_setup
  make_fake zfs 1
}

@test "empty FALCON_DATASET means nothing to do" {
  FALCON_DATASET= run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^zfs'
}

@test "creates the dataset when it is missing" {
  printf '[[ $1 == create ]] && exit 0; n=$(grep -c "^zfs create" "$FAKE_LOG"); [[ $n -ge 1 ]] && exit 0; exit 1\n' > "$FAKE_BIN/zfs.script"
  FALCON_DATASET=fastpool/falcon run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^zfs create -p fastpool/falcon$'
}

@test "does nothing when the dataset exists" {
  make_fake zfs 0
  FALCON_DATASET=fastpool/falcon run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^zfs create'
}
