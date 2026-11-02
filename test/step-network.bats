load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/25-network.sh"

setup() {
  fakes_setup
  export HOMICRON_DHCPAGENT_DEFAULTS="$BATS_TEST_TMPDIR/dhcpagent"
  printf 'PARAM_REQUEST_LIST=1,121,3,6,12,15,26,28,43\nPARAM_IGNORE_LIST=\n' > "$HOMICRON_DHCPAGENT_DEFAULTS"
  export MGMT_LINKS=
  # chrony's state and the IPv4 routing table come from files the tests edit.
  echo online > "$BATS_TEST_TMPDIR/chrony-state"
  printf 'default              192.168.0.1          UG        2          0 igb0\n192.168.0.0          192.168.0.12         U         3          7 igb0\n' > "$BATS_TEST_TMPDIR/routes"
  make_fake svcs
  printf 'cat "%s"\n' "$BATS_TEST_TMPDIR/chrony-state" > "$FAKE_BIN/svcs.script"
  make_fake svcadm
  make_fake ipadm
  make_fake netstat
  printf 'cat "%s"\n' "$BATS_TEST_TMPDIR/routes" > "$FAKE_BIN/netstat.script"
}

@test "chrony online, no management links: nothing runs" {
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
  refute_called '^ipadm'
}

@test "enables chrony when it is not online" {
  echo disabled > "$BATS_TEST_TMPDIR/chrony-state"
  printf 'echo online > "%s"\n' "$BATS_TEST_TMPDIR/chrony-state" > "$FAKE_BIN/svcadm.script"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^svcadm enable -s chrony$'
}

@test "appends one line per management link and recycles each lease once" {
  MGMT_LINKS=igb1,igb2 run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx 'igb1.PARAM_IGNORE_LIST=3' "$HOMICRON_DHCPAGENT_DEFAULTS"
  grep -qx 'igb2.PARAM_IGNORE_LIST=3' "$HOMICRON_DHCPAGENT_DEFAULTS"
  assert_called '^ipadm delete-addr igb1/v4$'
  assert_called '^ipadm create-addr -T dhcp -w 20 igb1/v4$'
  assert_called '^ipadm create-addr -T dhcp -w 20 igb2/v4$'
  [[ "$output" == *"recycling the lease on igb1, an ssh on it drops"* ]]
  MGMT_LINKS=igb1,igb2 run "$STEP"
  [ "$(grep -c 'igb1.PARAM_IGNORE_LIST=3' "$HOMICRON_DHCPAGENT_DEFAULTS")" -eq 1 ]
}

@test "a line already present is not recycled" {
  echo 'igb1.PARAM_IGNORE_LIST=3' >> "$HOMICRON_DHCPAGENT_DEFAULTS"
  MGMT_LINKS=igb1 run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^ipadm'
}

@test "an empty element in MGMT_LINKS adds no line" {
  MGMT_LINKS=igb1, run "$STEP"
  [ "$status" -eq 0 ]
  ! grep -q '^\.PARAM_IGNORE_LIST' "$HOMICRON_DHCPAGENT_DEFAULTS"
  [ "$(grep -c 'PARAM_IGNORE_LIST=3' "$HOMICRON_DHCPAGENT_DEFAULTS")" -eq 1 ]
}

@test "a default route left on a management link fails the step" {
  printf 'default              192.168.0.1          UG        2          0 igb1\n' > "$BATS_TEST_TMPDIR/routes"
  echo 'igb1.PARAM_IGNORE_LIST=3' >> "$HOMICRON_DHCPAGENT_DEFAULTS"
  MGMT_LINKS=igb1 run "$STEP"
  [ "$status" -eq 1 ]
}

@test "a hand-written line that lists 3 among other options counts" {
  echo 'igb1.PARAM_IGNORE_LIST=3,6' >> "$HOMICRON_DHCPAGENT_DEFAULTS"
  MGMT_LINKS=igb1 run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^ipadm'
  [ "$(grep -c 'igb1.PARAM_IGNORE_LIST' "$HOMICRON_DHCPAGENT_DEFAULTS")" -eq 1 ]
}

@test "a default route that remains with the line present is named and the lease recycled" {
  printf 'default              192.168.0.1          UG        2          0 igb1\n' > "$BATS_TEST_TMPDIR/routes"
  echo 'igb1.PARAM_IGNORE_LIST=3' >> "$HOMICRON_DHCPAGENT_DEFAULTS"
  MGMT_LINKS=igb1 run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"igb1 still holds a default route via 192.168.0.1"* ]]
  assert_called '^ipadm delete-addr igb1/v4$'
  assert_called '^ipadm create-addr -T dhcp -w 20 igb1/v4$'
}
