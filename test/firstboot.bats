load helpers/fakes

SCRIPT="$BATS_TEST_DIRNAME/../firstboot/homicron-firstboot"

setup() {
  fakes_setup
  export HOMICRON_CONF="$BATS_TEST_TMPDIR/homicron.conf" HOMICRON_MSGLOG="$BATS_TEST_TMPDIR/msglog" HOMICRON_DHCP_WAIT=1
  printf 'HOSTNAME=host01\nBASE_URL=https://homicron.smithjs.org\n' > "$HOMICRON_CONF"
  make_fake dladm 0 $'rge0\nrge1'
  make_fake svcadm
  make_fake ipadm
  make_fake eventhook
  export HOMICRON_EVENTHOOK="$FAKE_BIN/eventhook"
}

@test "creates a dhcp v4 address on every physical link without one" {
  printf '[[ $1 == show-addr ]] && echo "rge0/v4"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  refute_called 'create-addr .*rge0/v4$'
  assert_called '^ipadm create-addr -T dhcp -w 0 rge1/v4$'
}

@test "a link with only a v6 address object still gets dhcp v4" {
  printf '[[ $1 == show-addr ]] && echo "rge0/v6"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  assert_called '^ipadm create-addr -T dhcp -w 0 rge0/v4$'
}

@test "enables ssh and mdns, then disables itself" {
  run "$SCRIPT"
  assert_called '^svcadm enable network/ssh$'
  assert_called '^svcadm enable network/dns/multicast$'
  assert_called '^svcadm disable site/homicron-firstboot$'
}

@test "writes hostname and addresses to msglog" {
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "10.0.2.15/24"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  grep -q 'host01' "$HOMICRON_MSGLOG"
  grep -q '10.0.2.15' "$HOMICRON_MSGLOG"
}

@test "exits 0 and reports when no dhcp address appears" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'no DHCP address after 1s' "$HOMICRON_MSGLOG"
  assert_called '^svcadm disable site/homicron-firstboot$'
}

@test "retries create-addr with -w 1 when -w 0 fails and left no address object" {
  printf '[[ $1 == create-addr && $* == *"-w 0"* ]] && exit 1; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called '^ipadm create-addr -T dhcp -w 1 rge0/v4$'
  assert_called '^ipadm create-addr -T dhcp -w 1 rge1/v4$'
  grep -q 'requested DHCP on rge0' "$HOMICRON_MSGLOG"
}

@test "a nonzero -w 0 that still created the address object is not an error" {
  printf '[[ $1 == create-addr ]] && exit 1; [[ $1 == show-addr && $* == *addrobj* ]] && { grep -q "^ipadm create-addr" "$FAKE_LOG" && printf "rge0/v4\\nrge1/v4\\n"; }; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  refute_called '^ipadm create-addr -T dhcp -w 1'
  ! grep -q 'failed' "$HOMICRON_MSGLOG"
}

@test "the ? placeholder does not count as an address" {
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "?"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'no DHCP address after 1s' "$HOMICRON_MSGLOG"
  ! grep -q '  ?' "$HOMICRON_MSGLOG"
}

@test "runs the dhcp hook once per link after the poll" {
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "10.0.2.15/24"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called '^eventhook rge0 BOUND$'
  assert_called '^eventhook rge1 BOUND$'
  [ "$(fake_calls | grep -c '^eventhook')" -eq 2 ]
}

@test "a missing hook is logged and the method still exits 0 and disables itself" {
  export HOMICRON_EVENTHOOK="$BATS_TEST_TMPDIR/absent"
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "10.0.2.15/24"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'dhcp hook' "$HOMICRON_MSGLOG"
  assert_called '^svcadm disable site/homicron-firstboot$'
}

@test "manifest is well-formed xml" {
  run xmllint --noout "$BATS_TEST_DIRNAME/../firstboot/homicron-firstboot.xml"
  [ "$status" -eq 0 ]
}
