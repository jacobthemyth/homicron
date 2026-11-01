SCRIPT="$BATS_TEST_DIRNAME/../pages/build-site.sh"

setup() { OUT="$BATS_TEST_TMPDIR/site"; }

@test "builds the expected layout" {
  run "$SCRIPT" "$OUT"
  [ "$status" -eq 0 ]
  for f in install firstboot/homicron-firstboot firstboot/homicron-firstboot.xml firstboot/dhcp-eventhook SHA256SUMS index.html .nojekyll; do
    [ -f "$OUT/$f" ]
  done
  [ ! -e "$OUT/CNAME" ]
  [ ! -e "$OUT/keys" ]
}

@test "SHA256SUMS verifies from the site root" {
  "$SCRIPT" "$OUT"
  cd "$OUT"
  if command -v sha256sum >/dev/null; then run sha256sum -c --quiet SHA256SUMS; else run shasum -a 256 -c --quiet SHA256SUMS; fi
  [ "$status" -eq 0 ]
  [ "$(wc -l < SHA256SUMS | tr -d ' ')" -eq 4 ]
}

@test "the served install equals the source apart from the base_url default" {
  HOMICRON_BASE_URL=http://example.test "$SCRIPT" "$OUT"
  grep -qx 'base_url=${HOMICRON_BASE_URL:-http://example.test}' "$OUT/install"
  cmp <(grep -v '^base_url=' "$OUT/install") <(grep -v '^base_url=' "$BATS_TEST_DIRNAME/../install/install.sh")
  grep -q 'HOMICRON_BASE_URL:-https://homicron.smithjs.org}' "$BATS_TEST_DIRNAME/../install/install.sh"
}

@test "without HOMICRON_BASE_URL the served install keeps the source default" {
  "$SCRIPT" "$OUT"
  cmp "$OUT/install" "$BATS_TEST_DIRNAME/../install/install.sh"
}

@test "index.html gets the base URL and the repository URL" {
  HOMICRON_BASE_URL=http://example.test HOMICRON_REPO_URL=https://example.test/o/r "$SCRIPT" "$OUT"
  grep -q 'http://example.test/install' "$OUT/index.html"
  grep -q 'https://example.test/o/r' "$OUT/index.html"
  ! grep -q '{{' "$OUT/index.html"
}

@test "refuses an output directory that is the repository or one of its parents" {
  # Run against a throwaway copy so a broken guard cannot touch the real repo.
  copy="$BATS_TEST_TMPDIR/copy/repo"
  mkdir -p "$copy"
  cp -R "$BATS_TEST_DIRNAME/../pages" "$BATS_TEST_DIRNAME/../install" "$BATS_TEST_DIRNAME/../firstboot" "$copy/"
  run "$copy/pages/build-site.sh" "$copy";                 [ "$status" -eq 2 ]
  run "$copy/pages/build-site.sh" "$copy/pages/..";        [ "$status" -eq 2 ]
  run "$copy/pages/build-site.sh" "$BATS_TEST_TMPDIR/copy"; [ "$status" -eq 2 ]
  cd "$copy" && run pages/build-site.sh .;                 [ "$status" -eq 2 ]
  [ -f "$copy/install/install.sh" ]
  run "$copy/pages/build-site.sh" "$BATS_TEST_TMPDIR/copy/out"; [ "$status" -eq 0 ]
}
