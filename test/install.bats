load helpers/fakes
load helpers/fake_site

SCRIPT="$BATS_TEST_DIRNAME/../install/install.sh"

setup() {
  fakes_setup
  export HOMICRON_BASE_URL=http://site.test HOMICRON_ALTROOT="$BATS_TEST_TMPDIR/a"
  export HOMICRON_INSTALL_HELIOS="$FAKE_BIN/install-helios"
  export HOMICRON_RESOLV_CONF="$BATS_TEST_TMPDIR/ramdisk-resolv.conf"
  printf 'nameserver 10.0.2.3\n' > "$HOMICRON_RESOLV_CONF"
  mkdir -p "$HOMICRON_ALTROOT/etc/svc" && : > "$HOMICRON_ALTROOT/etc/svc/repository.db"
  fake_site_setup "$BATS_TEST_TMPDIR/site"
  export HOMICRON_KEYS_URL=https://keys.test/user.keys FAKE_KEYS="$BATS_TEST_TMPDIR/user.keys"
  printf 'ssh-ed25519 AAAA test\n' > "$FAKE_KEYS"
  make_fake install-helios
  make_fake diskinfo 0 $'SCSI\tc1t0d0\tVirtio\tBlock Device\t100.00 GiB\tno\tno\nNVME\tc2t0d0\tVirtio\tBlock Device\t100.00 GiB\tno\tno'
  make_fake svccfg
}

file_mode() {
  if stat --version >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
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

@test "rejects a diskinfo TYPE word as a disk name" {
  run "$SCRIPT" host01 SCSI
  [ "$status" -eq 2 ]
  run "$SCRIPT" host01 NVME
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
  [[ "$output" == *"retry"* ]]
  refute_called '^install-helios'
}

@test "accepts a keys file whose only key is a hardware-backed sk- key" {
  printf 'sk-ssh-ed25519@openssh.com AAAA test\n' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  assert_called '^install-helios'
}

@test "an indented key line counts as a key" {
  printf '  ssh-ed25519 AAAA indented\n' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  assert_called '^install-helios'
}

@test "a comment-only keys file still counts as no key" {
  printf '# keys go here\n' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  refute_called '^install-helios'
}

@test "exits 1 before install when authorized_keys has no key" {
  : > "$FAKE_KEYS"
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
  cmp "$HOMICRON_ALTROOT/root/.ssh/authorized_keys" "$FAKE_KEYS"
  [ -x "$HOMICRON_ALTROOT/usr/lib/homicron-firstboot" ]
  [ -f "$HOMICRON_ALTROOT/lib/svc/manifest/site/homicron-firstboot.xml" ]
  [ -x "$HOMICRON_ALTROOT/etc/dhcp/eventhook" ]
  [ "$(file_mode "$HOMICRON_ALTROOT/etc/dhcp/eventhook")" = 755 ]
  cmp "$HOMICRON_ALTROOT/etc/dhcp/eventhook" "$BATS_TEST_DIRNAME/../firstboot/dhcp-eventhook"
  [ "$(cat "$HOMICRON_ALTROOT/etc/resolv.conf")" = "nameserver 10.0.2.3" ]
  grep -qx 'HOSTNAME=host01' "$HOMICRON_ALTROOT/etc/homicron.conf"
  grep -qx 'KEYS_URL=https://keys.test/user.keys' "$HOMICRON_ALTROOT/etc/homicron.conf"
  ! grep -q '^BASE_URL=' "$HOMICRON_ALTROOT/etc/homicron.conf"
  assert_called "^svccfg import $HOMICRON_ALTROOT/lib/svc/manifest/site/homicron-firstboot.xml$"
  assert_called "^SVCCFG_REPOSITORY=$HOMICRON_ALTROOT/etc/svc/repository.db$"
  [[ "${lines[-1]}" == "install complete; remove the media and run: reboot" ]]
  refute_called '^reboot'
}

@test "a ramdisk resolv.conf without a nameserver is not copied" {
  : > "$HOMICRON_RESOLV_CONF"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  [ ! -e "$HOMICRON_ALTROOT/etc/resolv.conf" ]
}

@test "a tampered hook fails the checksum before install" {
  echo tampered >> "$BATS_TEST_TMPDIR/site/firstboot/dhcp-eventhook"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  refute_called '^install-helios'
}

@test "propagates install-helios failure" {
  make_fake install-helios 7
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 7 ]
  [ ! -e "$HOMICRON_ALTROOT/etc/homicron.conf" ]
}

@test "no HOMICRON_KEYS_URL exits 2 with usage before any fetch" {
  unset HOMICRON_KEYS_URL
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOMICRON_KEYS_URL"* ]]
  [[ "$output" == *"github.com/<user>.keys"* ]]
  refute_called '^curl'
  refute_called '^install-helios'
}

@test "a keys URL that cannot be fetched exits 1 with the URL" {
  rm "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://keys.test/user.keys"* ]]
  refute_called '^install-helios'
}

@test "a keys file with a line that is not a key exits 1 with the line number" {
  printf 'ssh-ed25519 AAAA ok\n<html><body>Not Found</body></html>\n' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 2 is not a public key"* ]]
  refute_called '^install-helios'
}

@test "an option-prefixed key line counts as a key" {
  printf 'from="10.0.0.0/8",no-pty ssh-rsa AAAAB3 lab\n' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  assert_called '^install-helios'
}

@test "a keys file without a trailing newline keeps its last key" {
  printf 'ssh-ed25519 AAAA one\nssh-ed25519 BBBB two' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  grep -q 'BBBB two' "$HOMICRON_ALTROOT/root/.ssh/authorized_keys"
}

@test "the site keys path is never fetched" {
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  refute_called 'keys/authorized_keys'
}
