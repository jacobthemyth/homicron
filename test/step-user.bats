load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/10-user.sh"

setup() {
  fakes_setup
  export HOMICRON_USER=jacob HOMICRON_UID=501
  export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt" HOMICRON_ETC="$BATS_TEST_TMPDIR/etc" HOMICRON_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOMICRON_DIR" "$HOMICRON_ETC/default" "$HOMICRON_HOME"
  echo 'ssh-ed25519 AAAA test' > "$HOMICRON_DIR/authorized_keys"
  printf 'PATH=/usr/bin:/usr/sbin\n' > "$HOMICRON_ETC/default/login"
  for c in zfs useradd usermod passwd profiles userattr getent chown chmod; do make_fake "$c"; done
}

@test "does nothing when the end state already holds" {
  printf 'echo "jacob:x:501:10::/home/jacob:/bin/bash"\n' > "$FAKE_BIN/getent.script"
  printf 'echo "Primary Administrator"\n' > "$FAKE_BIN/profiles.script"
  printf 'echo "basic,net_icmpaccess"\n' > "$FAKE_BIN/userattr.script"
  mkdir -p "$HOMICRON_HOME/jacob/.ssh"
  cp "$HOMICRON_DIR/authorized_keys" "$HOMICRON_HOME/jacob/.ssh/"
  printf 'PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/login"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^useradd'
  refute_called '^zfs create'
  refute_called '^usermod'
}

@test "creates everything when the user is missing" {
  make_fake getent 2
  make_fake zfs 1
  printf '[[ $1 == create ]] && exit 0; exit 1\n' > "$FAKE_BIN/zfs.script"
  run "$STEP"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  assert_called '^zfs create -o mountpoint=/home/jacob rpool/home/jacob$'
  assert_called '^useradd -u 501 -g staff -d /home/jacob -s /bin/bash -P Primary Administrator jacob$'
  assert_called '^passwd -N jacob$'
  assert_called '^usermod -K defaultpriv=basic,net_icmpaccess jacob$'
  grep -q '/opt/ooce/bin:/opt/ooce/sbin' "$HOMICRON_ETC/default/login"
  [ "$(grep -c '^PATH=' "$HOMICRON_ETC/default/login")" -eq 1 ]
  cmp "$HOMICRON_HOME/jacob/.ssh/authorized_keys" "$HOMICRON_DIR/authorized_keys"
}

@test "adds only what is missing when the user exists" {
  printf 'echo "jacob:x:501:10::/home/jacob:/bin/bash"\n' > "$FAKE_BIN/getent.script"
  printf 'echo "Primary Administrator"\n' > "$FAKE_BIN/profiles.script"
  printf 'echo "basic"\n' > "$FAKE_BIN/userattr.script"
  run "$STEP"
  refute_called '^useradd'
  assert_called '^usermod -K defaultpriv=basic,net_icmpaccess jacob$'
}
