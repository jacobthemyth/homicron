load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/87-propolis.sh"
REV=5e201ec4185ccb9182cc6ffcb09fadd9deee24ca
URL=https://buildomat.eng.oxide.computer/public/file/oxidecomputer/propolis/falcon/$REV/propolis-server

setup() {
  fakes_setup
  export HOMICRON_USER=vmuser HOMICRON_HOME="$BATS_TEST_TMPDIR/home"
  export HOMICRON_PROPOLIS_DIR="$BATS_TEST_TMPDIR/propolis"
  SRC="$HOMICRON_HOME/vmuser/src/voxel"
  mkdir -p "$SRC/target/release"
  printf '[workspace.dependencies]\npropolis-client = { git = "https://github.com/oxidecomputer/propolis", rev = "%s" }\n' "$REV" > "$SRC/Cargo.toml"
  make_fake su
  printf 'while [[ $1 != -c ]]; do shift; done; printf "%%s\\n" "$2" >> "$FAKE_LOG.su"; HOME="$HOMICRON_HOME/$HOMICRON_USER" bash -c "$2"\n' > "$FAKE_BIN/su.script"
  CONF="$BATS_TEST_TMPDIR/voxel.conf"; : > "$CONF"
  cat > "$SRC/target/release/voxel" <<EOS
#!/bin/bash
printf '%s\n' "voxel \$*" >> "$FAKE_LOG"
case "\$1 \$2" in
  "config get") awk -v k="\$3" '\$1 == k { print "\\"" \$2 "\\"" }' "$CONF" ;;
  "config set") printf '%s %s\n' "\$3" "\$4" >> "$CONF" ;;
esac
EOS
  chmod +x "$SRC/target/release/voxel"
  # curl: the digest URL prints $DIGEST, the binary URL writes $BODY to the -o target.
  export BODY="$BATS_TEST_TMPDIR/body" DIGEST="$BATS_TEST_TMPDIR/digest"
  printf 'binary\n' > "$BODY"
  shasum -a 256 "$BODY" | cut -d" " -f1 > "$DIGEST"
  make_fake curl
  cat > "$FAKE_BIN/curl.script" <<'EOS'
url="${*: -1}"
case "$url" in
  *.sha256.txt) cat "$DIGEST" ;;
  *) out=; while (( $# )); do [[ $1 == -o ]] && out=$2; shift; done; cp "$BODY" "$out" ;;
esac
EOS
  # digest -a sha256 FILE, the illumos form; the Mac has shasum.
  make_fake digest
  printf 'shasum -a 256 "${*: -1}" | cut -d" " -f1\n' > "$FAKE_BIN/digest.script"
}

@test "downloads the digest then the binary with retries, installs, and sets the key" {
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called "^curl -fsSL --retry 5 --retry-all-errors $URL.sha256.txt$"
  assert_called "^curl -fsSL --retry 5 --retry-all-errors -C - -o $HOMICRON_PROPOLIS_DIR/$REV.part $URL$"
  [ -x "$HOMICRON_PROPOLIS_DIR/$REV" ]
  [ ! -e "$HOMICRON_PROPOLIS_DIR/$REV.part" ]
  [[ "$(cat "$HOMICRON_PROPOLIS_DIR/$REV.sha256")" == "$(cat "$DIGEST")" ]]
  assert_called "^voxel config set falcon.propolis_binary $HOMICRON_PROPOLIS_DIR/$REV$"
}

@test "a matching binary and key skip the download" {
  run "$STEP"
  [ "$status" -eq 0 ]
  : > "$FAKE_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^curl'
  refute_called '^voxel config set'
}

@test "a digest mismatch deletes the part file and exits 1 with both digests" {
  echo 0000000000000000000000000000000000000000000000000000000000000000 > "$DIGEST"
  run "$STEP"
  [ "$status" -eq 1 ]
  [ ! -e "$HOMICRON_PROPOLIS_DIR/$REV.part" ]
  [ ! -e "$HOMICRON_PROPOLIS_DIR/$REV" ]
  [[ "$output" == *0000000000000000* ]]
  [[ "$output" == *"$(shasum -a 256 "$BODY" | cut -d" " -f1)"* ]]
  refute_called '^voxel config set'
}

@test "the default directory is outside /opt/homicron, which the runner's rsync --delete owns" {
  default=$(sed -n 's/^dir=\${HOMICRON_PROPOLIS_DIR:-\(.*\)}$/\1/p' "$STEP")
  [ -n "$default" ]
  [[ $default != *opt/homicron* ]]
  [[ $default == '${HOMICRON_STATE_DIR:-/var/homicron}/propolis' ]]
}

@test "a Cargo.toml without the rev exits 1" {
  : > "$SRC/Cargo.toml"
  run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read the propolis rev from voxel's Cargo.toml"* ]]
  refute_called '^curl'
}

@test "without HOMICRON_PROPOLIS_DIR the binary lands under the state directory" {
  unset HOMICRON_PROPOLIS_DIR
  export HOMICRON_STATE_DIR="$BATS_TEST_TMPDIR/state"
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -x "$HOMICRON_STATE_DIR/propolis/$REV" ]
  assert_called "^voxel config set falcon.propolis_binary $HOMICRON_STATE_DIR/propolis/$REV$"
}
