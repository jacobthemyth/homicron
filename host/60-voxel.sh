#!/bin/bash
#
# Step 60: clone and build voxel as $HOMICRON_USER.
#
# End state: ~/src/voxel is checked out at $VOXEL_REF and
# target/release/voxel was built from that commit (recorded in
# target/.homicron-built; mtimes are not used because a docs-only upstream
# commit moves HEAD without changing the binary).
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

home_root=${HOMICRON_HOME:-/home}
src="$home_root/$HOMICRON_USER/src/voxel"
marker="$src/target/.homicron-built"
repo=https://github.com/oxidecomputer/voxel
ref=$VOXEL_REF

have_checkout() {
  [[ -d $src/.git ]]
}

fetch() {
  as_user "cd $src && git fetch -q origin"
}

head_commit() {
  as_user "cd $src && git rev-parse HEAD"
}

# The commit $ref names: a branch on origin first, then a tag or commit id.
# --verify -q prints one line or nothing; without it git echoes the failed
# name to stdout as well.
resolve_ref() {
  as_user "cd $src && { git rev-parse --verify -q 'origin/$ref^{commit}' || git rev-parse --verify -q '$ref^{commit}'; }"
}

at_ref() {
  fetch && [[ $(head_commit) == "$(resolve_ref)" ]]
}

binary_fresh() {
  [[ -x $src/target/release/voxel && -f $marker ]] && [[ $(cat "$marker") == "$(head_commit)" ]]
}

check() {
  have_checkout && at_ref && binary_fresh
}

apply() {
  local commit
  if ! have_checkout; then
    log "cloning $repo into $src"
    as_user "mkdir -p $(dirname "$src") && git clone $repo $src"
  fi
  # check fetched already, or the clone is fresh; no second fetch.
  commit=$(resolve_ref) || { log "VOXEL_REF $ref names no commit on origin or locally"; exit 1; }
  log "checking out $commit ($ref)"
  as_user "cd $src && git checkout --detach $commit"
  log "cargo build --release (this takes a while)"
  as_user "cd $src && PATH=\$HOME/.cargo/bin:\$PATH cargo build --release"
  as_user "cd $src && git rev-parse HEAD > $marker"
}

step_main
