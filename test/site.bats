SCRIPT="$BATS_TEST_DIRNAME/../pages/build-site.sh"

setup() { OUT="$BATS_TEST_TMPDIR/site"; }

@test "builds the expected layout" {
  run "$SCRIPT" "$OUT"
  [ "$status" -eq 0 ]
  for f in install firstboot/homicron-firstboot firstboot/homicron-firstboot.xml keys/authorized_keys SHA256SUMS index.html CNAME .nojekyll; do
    [ -f "$OUT/$f" ]
  done
  [ "$(cat "$OUT/CNAME")" = "homicron.smithjs.org" ]
}

@test "SHA256SUMS verifies from the site root" {
  "$SCRIPT" "$OUT"
  cd "$OUT"
  if command -v sha256sum >/dev/null; then run sha256sum -c --quiet SHA256SUMS; else run shasum -a 256 -c --quiet SHA256SUMS; fi
  [ "$status" -eq 0 ]
  [ "$(wc -l < SHA256SUMS | tr -d ' ')" -eq 4 ]
}

@test "install is byte-identical to install/install.sh" {
  "$SCRIPT" "$OUT"
  cmp "$OUT/install" "$BATS_TEST_DIRNAME/../install/install.sh"
}
