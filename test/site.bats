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

@test "refuses an output directory that is the repository or one of its parents" {
  # Run against a throwaway copy so a broken guard cannot touch the real repo.
  copy="$BATS_TEST_TMPDIR/copy/repo"
  mkdir -p "$copy"
  cp -R "$BATS_TEST_DIRNAME/../pages" "$BATS_TEST_DIRNAME/../install" "$BATS_TEST_DIRNAME/../firstboot" "$BATS_TEST_DIRNAME/../keys" "$copy/"
  run "$copy/pages/build-site.sh" "$copy";                 [ "$status" -eq 2 ]
  run "$copy/pages/build-site.sh" "$copy/pages/..";        [ "$status" -eq 2 ]
  run "$copy/pages/build-site.sh" "$BATS_TEST_TMPDIR/copy"; [ "$status" -eq 2 ]
  cd "$copy" && run pages/build-site.sh .;                 [ "$status" -eq 2 ]
  [ -f "$copy/install/install.sh" ]
  run "$copy/pages/build-site.sh" "$BATS_TEST_TMPDIR/copy/out"; [ "$status" -eq 0 ]
}
