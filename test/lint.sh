#!/bin/bash
#
# Run bash -n and the shellcheck linter over every script in the repository.
#
set -o errexit -o pipefail -o nounset
cd "$(dirname "$0")/.."

shopt -s nullglob
files=(
  install/*.sh
  firstboot/homicron-firstboot
  host/*.sh
  bin/homicron
  test/*.sh
  test/helpers/*.bash
  pages/*.sh
)

if (( ${#files[@]} == 0 )); then
  echo "lint: no scripts found" >&2
  exit 1
fi

existing=()
for f in "${files[@]}"; do
  [[ -f $f ]] && existing+=("$f")
done

status=0
for f in "${existing[@]}"; do
  bash -n "$f" || status=1
done
shellcheck --shell=bash "${existing[@]}" || status=1
exit $status
