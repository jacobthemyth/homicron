load helpers/fakes
load helpers/fake_site

SCRIPT="$BATS_TEST_DIRNAME/../install/install.sh"

setup() {
  fakes_setup
  export HOMICRON_BASE_URL=http://site.test HOMICRON_ALTROOT="$BATS_TEST_TMPDIR/a"
  export HOMICRON_INSTALL_HELIOS="$FAKE_BIN/install-helios"
  mkdir -p "$HOMICRON_ALTROOT/etc/svc" && : > "$HOMICRON_ALTROOT/etc/svc/repository.db"
  fake_site_setup "$BATS_TEST_TMPDIR/site"
  make_fake install-helios
  make_fake diskinfo 0 $'c1t0d0\nc2t0d0'
  make_fake svccfg
}

file_mode() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

@test "refuses to run outside the installer" {
  rm "$FAKE_BIN/install-helios"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 2 ]
  [[ "$output" == *"not the Helios installer"* ]]
}

@test "usage: needs 2..4 args and disks must be in diskinfo" {
  run "$SCRIPT" host01
  [ "$status" -eq 2 ]
  run "$SCRIPT" host01 a b c d
  [ "$status" -eq 2 ]
  run "$SCRIPT" host01 c9t9d9
  [ "$status" -eq 2 ]
  refute_called '^install-helios'
}

@test "rejects a hostname illumos would not accept" {
  run "$SCRIPT" "Host 01" c1t0d0
  [ "$status" -eq 2 ]
  run "$SCRIPT" host_01 c1t0d0
  [ "$status" -eq 2 ]
  refute_called '^install-helios'
}

@test "exits 1 before install on checksum mismatch" {
  echo tampered >> "$BATS_TEST_TMPDIR/site/firstboot/homicron-firstboot"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  refute_called '^install-helios'
}

@test "exits 1 before install when authorized_keys has no key" {
  : > "$BATS_TEST_TMPDIR/site/keys/authorized_keys"
  fake_site_resum "$BATS_TEST_TMPDIR/site"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  refute_called '^install-helios'
}

@test "happy path seeds the altroot and enables the service" {
  printf 'env | grep ^SVCCFG_REPOSITORY= >> "$FAKE_LOG"; exit 0\n' > "$FAKE_BIN/svccfg.script"
  run "$SCRIPT" host01 c1t0d0 c2t0d0
  [ "$status" -eq 0 ]
  assert_called '^install-helios host01 c1t0d0 c2t0d0$'
  [ "$(file_mode "$HOMICRON_ALTROOT/root/.ssh/authorized_keys")" = 600 ]
  cmp "$HOMICRON_ALTROOT/root/.ssh/authorized_keys" "$BATS_TEST_TMPDIR/site/keys/authorized_keys"
  [ -x "$HOMICRON_ALTROOT/usr/lib/homicron-firstboot" ]
  [ -f "$HOMICRON_ALTROOT/lib/svc/manifest/site/homicron-firstboot.xml" ]
  grep -qx 'HOSTNAME=host01' "$HOMICRON_ALTROOT/etc/homicron.conf"
  grep -qx 'BASE_URL=http://site.test' "$HOMICRON_ALTROOT/etc/homicron.conf"
  assert_called "^svccfg import $HOMICRON_ALTROOT/lib/svc/manifest/site/homicron-firstboot.xml$"
  assert_called "^SVCCFG_REPOSITORY=$HOMICRON_ALTROOT/etc/svc/repository.db$"
  [[ "${lines[-1]}" == "install complete; remove the media and run: reboot" ]]
  refute_called '^reboot'
}

@test "propagates install-helios failure" {
  make_fake install-helios 7
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 7 ]
  [ ! -e "$HOMICRON_ALTROOT/etc/homicron.conf" ]
}
