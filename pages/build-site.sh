#!/bin/bash
#
# Assemble the static site served by GitHub Pages.
#
#   pages/build-site.sh [OUTDIR]     default OUTDIR is _site
#
# The stage directories are the single source of truth; this script only
# copies them into the layout install.sh expects and writes SHA256SUMS.
#
# HOMICRON_BASE_URL   the address the site is served at. It becomes the
#                     default inside the served install script and fills
#                     {{BASE_URL}} in index.html. The workflow passes the
#                     address GitHub Pages reports, so a fork needs no edit.
# HOMICRON_REPO_URL   fills {{REPO_URL}} in index.html.
#
set -o errexit -o pipefail -o nounset

root=$(cd "$(dirname "$0")/.." && pwd -P)
out=${1:-"$root/_site"}
base_url=${HOMICRON_BASE_URL:-https://homicron.smithjs.org}
repo_url=${HOMICRON_REPO_URL:-https://github.com/jacobthemyth/homicron}

sum_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

# Refuse to empty the repository itself or any directory above it. A
# directory that does not exist yet cannot contain the repository.
if canon=$(cd "$out" 2>/dev/null && pwd -P); then
  if [[ $canon == / || $root == "$canon" || $root == "$canon"/* ]]; then
    printf 'build-site: refusing to use %s as the output directory\n' "$out" >&2
    exit 2
  fi
fi
rm -rf "$out"
mkdir -p "$out/firstboot"

# One line of install.sh changes: the default inside base_url=${...:-...}.
sed -e "s|^base_url=\${HOMICRON_BASE_URL:-.*}\$|base_url=\${HOMICRON_BASE_URL:-$base_url}|" "$root/install/install.sh" > "$out/install"
cp "$root"/firstboot/* "$out/firstboot/"

(
  cd "$out" || exit 1
  sum_tool install firstboot/* > SHA256SUMS
)

sed -e "s|{{BASE_URL}}|$base_url|g" -e "s|{{REPO_URL}}|$repo_url|g" "$root/pages/index.html" > "$out/index.html"
cp "$root/pages/.nojekyll" "$out/"

printf 'site built in %s\n' "$out"
