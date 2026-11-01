#!/bin/bash
#
# Step 60: clone and build voxel as $HOMICRON_USER.
#
# End state: ~/src/voxel is checked out at $VOXEL_REF and
# target/release/voxel is newer than the checkout.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

home_root=${HOMICRON_HOME:-/home}
src="$home_root/$HOMICRON_USER/src/voxel"
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

target_commit() {
  as_user "cd $src && { git rev-parse 'origin/$ref^{commit}' 2>/dev/null || git rev-parse '$ref^{commit}'; }"
}

at_ref() {
  fetch && [[ $(head_commit) == "$(target_commit)" ]]
}

binary_fresh() {
  [[ $src/target/release/voxel -nt $src/.git/HEAD ]]
}

check() {
  have_checkout && at_ref && binary_fresh
}

apply() {
  if ! have_checkout; then
    log "cloning $repo into $src"
    as_user "mkdir -p $(dirname "$src") && git clone $repo $src"
  fi
  log "checking out $ref"
  fetch
  as_user "cd $src && { git checkout --detach 'origin/$ref' 2>/dev/null || git checkout --detach '$ref'; }"
  log "cargo build --release (this takes a while)"
  as_user "cd $src && PATH=\$HOME/.cargo/bin:\$PATH cargo build --release"
}

step_main
