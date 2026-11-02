load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/80-voxel-images.sh"

setup() {
  fakes_setup
  export HOMICRON_USER=vmuser HOMICRON_HOME="$BATS_TEST_TMPDIR/home"
  SRC="$HOMICRON_HOME/vmuser/src/voxel"
  make_fake su
  printf 'while [[ $1 != -c ]]; do shift; done; printf "%%s\\n" "$2" >> "$FAKE_LOG.su"; HOME="$HOMICRON_HOME/$HOMICRON_USER" bash -c "$2"\n' > "$FAKE_BIN/su.script"
  make_fake pfexec
  printf '"$@"\n' > "$FAKE_BIN/pfexec.script"
  # A fake voxel at the real path. `image list` prints the registered names
  # from $IMAGES in voxel's layout; the create commands register a name, or
  # fail when $FAKE_BIN/voxel-create-fails exists.
  mkdir -p "$SRC/target/release"
  export IMAGES="$BATS_TEST_TMPDIR/images"; : > "$IMAGES"
  cat > "$SRC/target/release/voxel" <<EOS
#!/bin/bash
printf '%s\n' "voxel \$*" >> "$FAKE_LOG"
case "\$1 \$2" in
  "image list")
    printf 'images under rpool/falcon/img:\n\n  %-50s %-6s %-22s %s\n' IMAGE SIZE CREATED COMMIT
    # A name that starts with * is the current image.cp: voxel marks that row
    # with * in the first column and adds a footer.
    while read -r name; do
      if [[ \$name == \** ]]; then printf '*  %-50s %-6s %-22s %s\n' "\${name#\*}" 10.2G "Mon Nov  2 23:37 2026" abc123; marked=1
      else printf '   %-50s %-6s %-22s %s\n' "\$name" 1.3G "Mon Nov  2 23:40 2026" -; fi
    done < "$IMAGES"
    [[ -n \${marked:-} ]] && printf '\n* = current image.cp\n' ;;
  "image create")
    [[ -e "$FAKE_BIN/voxel-create-fails" ]] && exit 1
    echo voxel-cp-abc123 >> "$IMAGES" ;;
  "image create-frr") echo voxel-frr-proto >> "$IMAGES" ;;
esac
exit 0
EOS
  chmod +x "$SRC/target/release/voxel"
}

@test "both images present: nothing runs" {
  printf 'voxel-frr-proto\nvoxel-cp-77901ac4bb2d6e1ac6dd7380b3758129b73f69cd\n' > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called 'image create'
}

@test "no images: builds cp then frr through pfexec as the user" {
  : > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$(fake_calls | grep -o '^voxel image create.*' | cut -d" " -f2- | tr '\n' '|')" == 'image create|image create-frr proto|' ]]
  assert_called '^su - vmuser -c pfexec .*voxel image create$'
}

@test "only the missing image is built" {
  printf 'voxel-cp-abc\n' > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called 'image create$'
  assert_called 'image create-frr proto$'
}

@test "a failed cp build stops before frr and the step fails" {
  : > "$IMAGES"
  : > "$FAKE_BIN/voxel-create-fails"
  run "$STEP"
  [ "$status" -ne 0 ]
  assert_called 'image create$'
  refute_called 'create-frr'
}

@test "the current image marked with * is still seen" {
  printf 'voxel-frr-proto\n*voxel-cp-77901ac4bb2d6e1ac6dd7380b3758129b73f69cd\n' > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called 'image create'
}

@test "a long image list after the names still counts as present" {
  cat > "$SRC/target/release/voxel" <<EOS
#!/bin/bash
printf '%s\n' "voxel \$*" >> "$FAKE_LOG"
printf 'images under rpool/falcon/img:\n\n   IMAGE SIZE CREATED COMMIT\n   voxel-frr-proto 1.3G x -\n*  voxel-cp-abc 10G x abc\n\n* = current image.cp\n'
seq 1 300000
EOS
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in the desired state"* ]]
}
