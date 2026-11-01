#!/bin/bash
#
# Assemble the static site served by GitHub Pages.
#
#   pages/build-site.sh [OUTDIR]     default OUTDIR is _site
#
# The stage directories are the single source of truth; this script only
# copies them into the layout install.sh expects and writes SHA256SUMS.
#
set -o errexit -o pipefail -o nounset

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/_site"}

sum_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

rm -rf "$out"
mkdir -p "$out/firstboot" "$out/keys"

cp "$root/install/install.sh" "$out/install"
cp "$root/firstboot/homicron-firstboot" "$root/firstboot/homicron-firstboot.xml" "$out/firstboot/"
cp "$root/keys/authorized_keys" "$out/keys/authorized_keys"

(
  cd "$out" || exit 1
  sum_tool install firstboot/homicron-firstboot firstboot/homicron-firstboot.xml keys/authorized_keys > SHA256SUMS
)

cp "$root/pages/index.html" "$root/pages/CNAME" "$root/pages/.nojekyll" "$out/"

printf 'site built in %s\n' "$out"
