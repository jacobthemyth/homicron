load fakes

setup() { fakes_setup; }

@test "make_fake records calls and returns exit code" {
  make_fake zfs 3 "hello"
  run zfs list -H rpool
  [ "$status" -eq 3 ]
  [ "$output" = "hello" ]
  assert_called '^zfs list -H rpool$'
  refute_called '^zpool'
}

@test "make_fake sources NAME.script when present" {
  make_fake ipadm
  printf '[[ $1 == show-addr ]] && echo "lo0/v4"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run ipadm show-addr -p -o addrobj
  [ "$output" = "lo0/v4" ]
}
