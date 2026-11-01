#!/bin/bash
#
# Step 70: voxel.toml values for this host.
#
# End state: `voxel config get` returns the configured topology.sleds,
# topology.sled_memory_gb, and (when FALCON_DATASET is set) falcon.dataset.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

home_root=${HOMICRON_HOME:-/home}
voxel="$home_root/$HOMICRON_USER/src/voxel/target/release/voxel"

keys=(topology.sleds topology.sled_memory_gb)
values=("$VOXEL_SLEDS" "$VOXEL_SLED_MEMORY_GB")
if [[ -n ${FALCON_DATASET:-} ]]; then
  keys+=(falcon.dataset)
  values+=("$FALCON_DATASET")
fi

# `config get` prints a string value as a TOML literal, with its quotes.
current() {
  as_user "$voxel config get $1" 2>/dev/null | sed -e 's/^"//' -e 's/"$//' || true
}

check() {
  local i
  for i in "${!keys[@]}"; do
    [[ $(current "${keys[$i]}") == "${values[$i]}" ]] || return 1
  done
}

apply() {
  local i
  for i in "${!keys[@]}"; do
    if [[ $(current "${keys[$i]}") != "${values[$i]}" ]]; then
      log "voxel config set ${keys[$i]} ${values[$i]}"
      as_user "$voxel config set ${keys[$i]} ${values[$i]}"
    fi
  done
}

step_main
