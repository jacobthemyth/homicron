load helpers/fakes

STEP="$BATS_TEST_DIRNAME/../host/70-voxel-conf.sh"

setup() {
  fakes_setup
  export HOMICRON_USER=vmuser HOMICRON_HOME="$BATS_TEST_TMPDIR/home" VOXEL_SLEDS=4 VOXEL_SLED_MEMORY_GB=8
  export FALCON_DATASET=
  SRC="$HOMICRON_HOME/vmuser/src/voxel"
  make_fake su
  printf 'while [[ $1 != -c ]]; do shift; done; printf "%%s\\n" "$2" >> "$FAKE_LOG.su"; HOME="$HOMICRON_HOME/$HOMICRON_USER" bash -c "$2"\n' > "$FAKE_BIN/su.script"
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

@test "does nothing when every value already matches" {
  printf 'topology.sleds 4\ntopology.sled_memory_gb 8\n' > "$CONF"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^voxel config set'
}

@test "sets the values that differ" {
  printf 'topology.sled_memory_gb 8\n' > "$CONF"
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^voxel config set topology.sleds 4$'
  refute_called '^voxel config set topology.sled_memory_gb'
}

@test "sets falcon.dataset only when FALCON_DATASET is set" {
  run "$STEP"
  refute_called 'falcon.dataset'
  FALCON_DATASET=fastpool/falcon run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^voxel config set falcon.dataset fastpool/falcon$'
}

@test "a string value already set converges although config get quotes it" {
  printf 'topology.sleds 4\ntopology.sled_memory_gb 8\nfalcon.dataset fastpool/falcon\n' > "$CONF"
  FALCON_DATASET=fastpool/falcon run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^voxel config set'
}
