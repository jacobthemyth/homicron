load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/85-voxel-conf.sh"

setup() {
  fakes_setup
  export HOMICRON_USER=vmuser HOMICRON_HOME="$BATS_TEST_TMPDIR/home" VOXEL_SLEDS=4 VOXEL_SLED_MEMORY_GB=8
  export FALCON_DATASET= VOXEL_CP_IMAGE= VOXEL_EXTERNAL_MODE=lan VOXEL_EXTERNAL_UPLINK=
  SRC="$HOMICRON_HOME/vmuser/src/voxel"
  make_fake su
  printf 'while [[ $1 != -c ]]; do shift; done; printf "%%s\\n" "$2" >> "$FAKE_LOG.su"; HOME="$HOMICRON_HOME/$HOMICRON_USER" bash -c "$2"\n' > "$FAKE_BIN/su.script"
  # zfs list prints the image datasets from $IMAGES.
  export IMAGES="$BATS_TEST_TMPDIR/images"
  printf 'rpool/falcon/img/voxel-cp-abc\nrpool/falcon/img/voxel-frr-proto\n' > "$IMAGES"
  make_fake zfs
  printf 'cat "$IMAGES"\n' > "$FAKE_BIN/zfs.script"
  # A fake voxel binary at the real path: `config get KEY` and `config set KEY VALUE` over a flat file.
  mkdir -p "$SRC/target/release"
  CONF="$BATS_TEST_TMPDIR/voxel.conf"; : > "$CONF"
  cat > "$SRC/target/release/voxel" <<EOS
#!/bin/bash
printf '%s\n' "voxel \$*" >> "$FAKE_LOG"
case "\$1 \$2" in
  "config get") awk -v k="\$3" '\$1 == k { if (\$2 ~ /^[0-9]+\$/) print \$2; else print "\\"" \$2 "\\"" }' "$CONF" ;;
  "config set") printf '%s %s\n' "\$3" "\$4" >> "$CONF" ;;
esac
EOS
  chmod +x "$SRC/target/release/voxel"
}

converged() {
  printf 'topology.sleds 4\ntopology.sled_memory_gb 8\nimage.cp voxel-cp-abc\nimage.frr voxel-frr-proto\nexternal.mode lan\n' > "$CONF"
}

@test "does nothing when every value already matches" {
  converged
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^voxel config set'
}

@test "sets the values that differ" {
  converged
  sed -i '' '/^topology.sleds/d' "$CONF"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^voxel config set topology.sleds 4$'
  refute_called '^voxel config set topology.sled_memory_gb'
}

@test "sets falcon.dataset only when FALCON_DATASET is set" {
  run "$STEP"
  refute_called 'falcon.dataset'
  printf 'fast/falcon/img/voxel-cp-abc\n' > "$IMAGES"
  FALCON_DATASET=fast/falcon run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^voxel config set falcon.dataset fast/falcon$'
}

@test "a string value already set converges although config get quotes it" {
  converged
  printf 'falcon.dataset fast/falcon\n' >> "$CONF"
  printf 'fast/falcon/img/voxel-cp-abc\n' > "$IMAGES"
  FALCON_DATASET=fast/falcon run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^voxel config set'
}

@test "selects the one cp image under the dataset" {
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^zfs list -H -o name -r rpool/falcon/img$'
  assert_called '^voxel config set image.cp voxel-cp-abc$'
  assert_called '^voxel config set image.frr voxel-frr-proto$'
}

@test "lists under FALCON_DATASET when set" {
  printf 'fast/falcon/img/voxel-cp-abc\n' > "$IMAGES"
  FALCON_DATASET=fast/falcon run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^zfs list -H -o name -r fast/falcon/img$'
}

@test "VOXEL_CP_IMAGE wins over the search" {
  VOXEL_CP_IMAGE=voxel-cp-xyz run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^zfs'
  assert_called '^voxel config set image.cp voxel-cp-xyz$'
}

@test "no cp image exits 1 and names step 80" {
  printf 'rpool/falcon/img/voxel-frr-proto\n' > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no voxel-cp image under rpool/falcon/img; step 80 builds one"* ]]
  refute_called 'config set'
}

@test "two cp images exit 1 with both names" {
  printf 'rpool/falcon/img/voxel-cp-abc\nrpool/falcon/img/voxel-cp-def\n' > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one voxel-cp image under rpool/falcon/img: voxel-cp-abc voxel-cp-def; set VOXEL_CP_IMAGE"* ]]
  refute_called 'config set image.cp'
}

@test "isolated mode sets mode and uplink" {
  VOXEL_EXTERNAL_MODE=isolated VOXEL_EXTERNAL_UPLINK=igb0 run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^voxel config set external.mode isolated$'
  assert_called '^voxel config set external.uplink igb0$'
}

@test "lan mode sets no uplink" {
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called 'external.uplink'
}

@test "isolated without an uplink exits 1" {
  VOXEL_EXTERNAL_MODE=isolated run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VOXEL_EXTERNAL_UPLINK is required in isolated mode"* ]]
  refute_called 'config set'
}
