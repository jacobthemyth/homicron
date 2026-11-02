load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/10-user.sh"

setup() {
  fakes_setup
  export HOMICRON_USER=vmuser HOMICRON_UID=501
  export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt" HOMICRON_ETC="$BATS_TEST_TMPDIR/etc" HOMICRON_HOME="$BATS_TEST_TMPDIR/home"
  export HOMICRON_ROOT_HOME="$BATS_TEST_TMPDIR/root"
  mkdir -p "$HOMICRON_DIR" "$HOMICRON_ETC/default" "$HOMICRON_HOME" "$HOMICRON_ROOT_HOME"
  echo 'ssh-ed25519 AAAA test' > "$HOMICRON_DIR/authorized_keys"
  printf 'PATH=/usr/bin:/usr/sbin\n' > "$HOMICRON_ETC/default/login"
  printf '#PATH=/usr/bin:\n#SUPATH=/usr/sbin:/usr/bin\n' > "$HOMICRON_ETC/default/su"
  for c in zfs useradd usermod passwd profiles userattr getent chown chmod; do make_fake "$c"; done
}

@test "does nothing when the end state already holds" {
  printf 'echo "vmuser:x:501:10::/home/vmuser:/bin/bash"\n' > "$FAKE_BIN/getent.script"
  printf 'printf "vmuser:\\n          Primary Administrator\\n          Basic Solaris User\\n"\n' > "$FAKE_BIN/profiles.script"
  printf 'echo "basic,net_icmpaccess"\n' > "$FAKE_BIN/userattr.script"
  mkdir -p "$HOMICRON_HOME/vmuser/.ssh" "$HOMICRON_ROOT_HOME/.ssh"
  cp "$HOMICRON_DIR/authorized_keys" "$HOMICRON_HOME/vmuser/.ssh/"
  cp "$HOMICRON_DIR/authorized_keys" "$HOMICRON_ROOT_HOME/.ssh/"
  printf 'PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/login"
  printf 'PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/su"
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
  assert_called '^zfs create -p -o mountpoint=/home/vmuser rpool/home/vmuser$'
  assert_called '^useradd -u 501 -g staff -d /home/vmuser -s /bin/bash -P Primary Administrator vmuser$'
  assert_called '^passwd -N vmuser$'
  assert_called '^usermod -K defaultpriv=basic,net_icmpaccess vmuser$'
  grep -q '/opt/ooce/bin:/opt/ooce/sbin' "$HOMICRON_ETC/default/login"
  [ "$(grep -c '^PATH=' "$HOMICRON_ETC/default/login")" -eq 1 ]
  cmp "$HOMICRON_HOME/vmuser/.ssh/authorized_keys" "$HOMICRON_DIR/authorized_keys"
}

@test "adds only what is missing when the user exists" {
  printf 'echo "vmuser:x:501:10::/home/vmuser:/bin/bash"\n' > "$FAKE_BIN/getent.script"
  printf 'printf "vmuser:\\n          Primary Administrator\\n"\n' > "$FAKE_BIN/profiles.script"
  printf 'echo "basic"\n' > "$FAKE_BIN/userattr.script"
  run "$STEP"
  refute_called '^useradd'
  assert_called '^usermod -K defaultpriv=basic,net_icmpaccess vmuser$'
}

@test "refuses an empty or comment-only keys file before any change" {
  make_fake getent 2
  for content in '' $'# nothing here\n\n'; do
    printf '%s' "$content" > "$HOMICRON_DIR/authorized_keys"
    run "$STEP"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no key"* ]]
  done
  refute_called '^useradd'
  refute_called '^zfs create'
  [ ! -e "$HOMICRON_HOME/vmuser/.ssh/authorized_keys" ]
}

@test "an indented key line counts as a key, as sshd reads it" {
  make_fake getent 2
  printf '  ssh-ed25519 AAAA indented\n' > "$HOMICRON_DIR/authorized_keys"
  run "$STEP"
  [[ "$output" != *"no key"* ]]
  assert_called '^useradd'
}

@test "converges root's authorized_keys as well as the user's" {
  make_fake getent 2
  run "$STEP"
  cmp "$HOMICRON_ROOT_HOME/.ssh/authorized_keys" "$HOMICRON_DIR/authorized_keys"
  assert_called "^chmod 0600 .*/root/.ssh/authorized_keys$"
}

@test "chown is not recursive" {
  make_fake getent 2
  run "$STEP"
  refute_called '^chown -R'
  assert_called "^chown vmuser:staff $HOMICRON_HOME/vmuser $HOMICRON_HOME/vmuser/.ssh $HOMICRON_HOME/vmuser/.ssh/authorized_keys$"
}

@test "uncomments a commented PATH line in /etc/default/login" {
  printf '# comment\n#PATH=/usr/bin:\n#SUPATH=/usr/sbin:/usr/bin\n' > "$HOMICRON_ETC/default/login"
  make_fake getent 2
  run "$STEP"
  [ "$(grep -c '^PATH=' "$HOMICRON_ETC/default/login")" -eq 1 ]
  grep -q '^PATH=/usr/bin:/opt/ooce/bin:/opt/ooce/sbin$' "$HOMICRON_ETC/default/login"
  grep -q '^#SUPATH=' "$HOMICRON_ETC/default/login"
}

# su - takes the new shell's PATH from /etc/default/su, not /etc/default/login;
# the stock default is a bare /usr/bin: (with the current directory on it).

@test "uncomments the stock PATH line in /etc/default/su with the login PATH" {
  make_fake getent 2
  run "$STEP"
  [ "$(grep -c '^PATH=' "$HOMICRON_ETC/default/su")" -eq 1 ]
  grep -q '^PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin$' "$HOMICRON_ETC/default/su"
  grep -q '^#SUPATH=/usr/sbin:/usr/bin$' "$HOMICRON_ETC/default/su"
}

@test "replaces an active PATH line in /etc/default/su that differs from login" {
  printf 'SULOG=/var/adm/sulog\nPATH=/usr/bin:\n' > "$HOMICRON_ETC/default/su"
  make_fake getent 2
  run "$STEP"
  [ "$(grep -c '^PATH=' "$HOMICRON_ETC/default/su")" -eq 1 ]
  grep -q '^SULOG=/var/adm/sulog$' "$HOMICRON_ETC/default/su"
  grep -q '^PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin$' "$HOMICRON_ETC/default/su"
}

@test "appends a PATH line to /etc/default/su that has none" {
  printf 'SYSLOG=YES\n' > "$HOMICRON_ETC/default/su"
  make_fake getent 2
  run "$STEP"
  [ "$(grep -c '^PATH=' "$HOMICRON_ETC/default/su")" -eq 1 ]
  grep -q '^SYSLOG=YES$' "$HOMICRON_ETC/default/su"
  grep -q '^PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin$' "$HOMICRON_ETC/default/su"
}

@test "a su PATH that already matches login is left alone" {
  printf 'PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/login"
  printf '# keep me\nPATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/su"
  make_fake getent 2
  run "$STEP"
  [[ $output != *default/su* ]]
  grep -q '^# keep me$' "$HOMICRON_ETC/default/su"
  [ "$(grep -c '^PATH=' "$HOMICRON_ETC/default/su")" -eq 1 ]
}

@test "a changed login PATH propagates to su on the next run" {
  printf 'PATH=/usr/bin:/usr/sbin:/usr/gnu/bin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/login"
  printf 'PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/su"
  make_fake getent 2
  run "$STEP"
  grep -q '^PATH=/usr/bin:/usr/sbin:/usr/gnu/bin:/opt/ooce/bin:/opt/ooce/sbin$' "$HOMICRON_ETC/default/su"
}

@test "long listings after the match still count as present" {
  # grep -q exits at the first match; under pipefail a producer still writing
  # dies of SIGPIPE and the pipeline fails at random. The fakes end with seq
  # so that status propagates.
  printf 'echo "vmuser:x:501:10::/home/vmuser:/bin/bash"\n' > "$FAKE_BIN/getent.script"
  printf 'printf "vmuser:\\n          Primary Administrator\\n"; seq 1 300000\n' > "$FAKE_BIN/profiles.script"
  printf 'echo "basic,net_icmpaccess"; seq 1 300000\n' > "$FAKE_BIN/userattr.script"
  mkdir -p "$HOMICRON_HOME/vmuser/.ssh" "$HOMICRON_ROOT_HOME/.ssh"
  cp "$HOMICRON_DIR/authorized_keys" "$HOMICRON_HOME/vmuser/.ssh/"
  cp "$HOMICRON_DIR/authorized_keys" "$HOMICRON_ROOT_HOME/.ssh/"
  printf 'PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/login"
  printf 'PATH=/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/ooce/sbin\n' > "$HOMICRON_ETC/default/su"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in the desired state"* ]]
}
