load helpers/fakes

HOOK="$BATS_TEST_DIRNAME/../firstboot/dhcp-eventhook"

setup() {
  fakes_setup
  export HOMICRON_RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf" HOMICRON_MSGLOG="$BATS_TEST_TMPDIR/msglog"
  make_fake svcadm
  make_fake dhcpinfo
  printf 'case "$*" in *DNSserv) printf "10.0.2.3 10.0.2.4\\n" ;; *DNSdmain) echo lan ;; esac; exit 0\n' > "$FAKE_BIN/dhcpinfo.script"
}

@test "BOUND writes domain and nameservers and refreshes dns/client" {
  run "$HOOK" rge0 BOUND
  [ "$status" -eq 0 ]
  [ "$(cat "$HOMICRON_RESOLV_CONF")" = $'domain lan\nnameserver 10.0.2.3\nnameserver 10.0.2.4' ]
  assert_called '^svcadm refresh network/dns/client$'
  grep -q 'wrote .*resolv.conf from rge0' "$HOMICRON_MSGLOG"
  [ -z "$(ls "$BATS_TEST_TMPDIR"/resolv.conf.tmp.* 2>/dev/null)" ]
}

@test "EXTEND and INFORM write, every other event leaves the file alone" {
  for ev in EXTEND INFORM; do
    rm -f "$HOMICRON_RESOLV_CONF"
    run "$HOOK" rge0 "$ev"
    [ -s "$HOMICRON_RESOLV_CONF" ]
  done
  printf 'nameserver 9.9.9.9\n' > "$HOMICRON_RESOLV_CONF"
  for ev in EXPIRE DROP RELEASE; do
    run "$HOOK" rge0 "$ev"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOMICRON_RESOLV_CONF")" = "nameserver 9.9.9.9" ]
  done
  [ "$(fake_calls | grep -c '^dhcpinfo')" -eq 4 ]
}

@test "a lease without DNS servers changes nothing and exits 0" {
  rm "$FAKE_BIN/dhcpinfo.script"
  make_fake dhcpinfo 1
  printf 'nameserver 9.9.9.9\n' > "$HOMICRON_RESOLV_CONF"
  run "$HOOK" rge0 BOUND
  [ "$status" -eq 0 ]
  [ "$(cat "$HOMICRON_RESOLV_CONF")" = "nameserver 9.9.9.9" ]
  refute_called '^svcadm'
}

@test "no domain in the lease gives nameserver lines only" {
  printf 'case "$*" in *DNSserv) echo 10.0.2.3 ;; *) exit 1 ;; esac; exit 0\n' > "$FAKE_BIN/dhcpinfo.script"
  run "$HOOK" rge0 BOUND
  [ "$(cat "$HOMICRON_RESOLV_CONF")" = "nameserver 10.0.2.3" ]
}
