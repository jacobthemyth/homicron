#!/bin/bash
#
# A fake copy of the published site for install.sh tests, plus a fake curl
# that serves it. Requires fakes_setup to have run (uses $FAKE_BIN).
#
# fake_site_setup DIR   copy the firstboot files and keys into DIR in site
#                       layout, write DIR/SHA256SUMS, install the fake curl
# fake_site_resum DIR   regenerate DIR/SHA256SUMS after editing a file

_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

_sum_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

fake_site_resum() {
  local dir="$1"
  (
    cd "$dir" || return 1
    _sum_tool firstboot/* keys/authorized_keys > SHA256SUMS
  )
}

fake_site_setup() {
  local dir="$1" root
  root=$(_repo_root)
  mkdir -p "$dir/firstboot" "$dir/keys"
  cp "$root"/firstboot/* "$dir/firstboot/"
  cp "$root/keys/authorized_keys" "$dir/keys/"
  fake_site_resum "$dir"
  export FAKE_SITE="$dir"

  make_fake curl
  cat > "$FAKE_BIN/curl.script" <<'SCRIPT'
out=
url=
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
rel="${url#"$HOMICRON_BASE_URL"/}"
src="$FAKE_SITE/$rel"
if [[ ! -f $src ]]; then
  echo "curl: (22) not found: $url" >&2
  exit 22
fi
if [[ -n $out ]]; then
  mkdir -p "$(dirname "$out")"
  cp "$src" "$out"
else
  cat "$src"
fi
exit 0
SCRIPT
}
