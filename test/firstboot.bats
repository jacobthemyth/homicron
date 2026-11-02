load helpers/fakes

SCRIPT="$BATS_TEST_DIRNAME/../firstboot/homicron-firstboot"

setup() {
  fakes_setup
  export HOMICRON_CONF="$BATS_TEST_TMPDIR/homicron.conf" HOMICRON_MSGLOG="$BATS_TEST_TMPDIR/msglog" HOMICRON_DHCP_WAIT=1 HOMICRON_LINK_WAIT=1
  printf 'HOSTNAME=host01\nKEYS_URL=https://github.com/user.keys\n' > "$HOMICRON_CONF"
  # Two links, both up. Tests that need a down link overwrite $LINK_STATE.
  make_fake dladm
  export LINK_STATE="$BATS_TEST_TMPDIR/link-state"
  printf 'rge0:up\nrge1:up\n' > "$LINK_STATE"
  printf 'if [[ $* == *link,state* ]]; then cat "$LINK_STATE"; else cut -d: -f1 "$LINK_STATE"; fi; exit 0\n' > "$FAKE_BIN/dladm.script"
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
  printf '[[ $1 == create-addr && $* == *dhcp* ]] && exit 1; [[ $1 == show-addr && $* == *addrobj* ]] && { grep -q "^ipadm create-addr" "$FAKE_LOG" && printf "rge0/v4\\nrge1/v4\\n"; }; exit 0\n' > "$FAKE_BIN/ipadm.script"
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

@test "a link that is down gets no DHCP, no addrconf, and no hook, and is reported" {
  printf 'rge0:up\nrge1:down\n' > "$LINK_STATE"
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "10.0.2.15/24"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called '^ipadm create-addr -T dhcp -w 0 rge0/v4$'
  refute_called 'rge1/v[46]$'
  refute_called '^eventhook rge1'
  grep -q 'rge1 has no link' "$HOMICRON_MSGLOG"
  grep -q 'ipadm create-addr -T dhcp rge1/v4' "$HOMICRON_MSGLOG"
}

@test "waits for a link to come up before deciding" {
  export HOMICRON_LINK_WAIT=5
  printf 'rge0:down\nrge1:down\n' > "$LINK_STATE"
  # The third state query finds rge0 up.
  printf 'if [[ $* == *link,state* ]]; then n=$(grep -c "link,state" "$FAKE_LOG"); (( n >= 3 )) && printf "rge0:up\\nrge1:down\\n" || cat "$LINK_STATE"; else cut -d: -f1 "$LINK_STATE"; fi; exit 0\n' > "$FAKE_BIN/dladm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called '^ipadm create-addr -T dhcp -w 0 rge0/v4$'
  refute_called 'rge1/v4$'
}

@test "requests addrconf v6 on every up link without a v6 address object" {
  printf '[[ $1 == show-addr ]] && [[ $* == *addrobj* ]] && echo "rge0/v6"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  refute_called '^ipadm create-addr -T addrconf rge0/v6$'
  assert_called '^ipadm create-addr -T addrconf rge1/v6$'
  assert_called '^ipadm create-addr -T dhcp -w 0 rge0/v4$'
}

@test "reports global v6 addresses, not link-local, with the colons unescaped" {
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && printf "10.0.2.15/24\\nfe80\\\\:\\\\:1%%%%rge0/10\\nfd69\\\\:\\\\:5/64\\n"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '  10.0.2.15/24' "$HOMICRON_MSGLOG"
  grep -q '  fd69::5/64' "$HOMICRON_MSGLOG"
  ! grep -q 'fe80' "$HOMICRON_MSGLOG"
  ! grep -q '\\' "$HOMICRON_MSGLOG"
}

@test "manifest is well-formed xml" {
  run xmllint --noout "$BATS_TEST_DIRNAME/../firstboot/homicron-firstboot.xml"
  [ "$status" -eq 0 ]
}
