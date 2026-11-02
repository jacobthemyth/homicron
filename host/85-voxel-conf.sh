#!/bin/bash
#
# Step 85: voxel.toml values for this host.
#
# End state: `voxel config get` returns the configured topology.sleds,
# topology.sled_memory_gb, image.cp, image.frr, external.mode, and (when
# FALCON_DATASET is set) falcon.dataset, and (in isolated mode)
# external.uplink. The step runs after step 80 so that the control plane
# image it selects exists. falcon.propolis_binary belongs to step 87.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

home_root=${HOMICRON_HOME:-/home}
voxel="$home_root/$HOMICRON_USER/src/voxel/target/release/voxel"
dataset=${FALCON_DATASET:-rpool/falcon}

# The control plane image: VOXEL_CP_IMAGE when set, else the one voxel-cp-*
# image under the dataset. Zero or several images stop the step, because
# voxel cannot guess either.
cp_image() {
  local names count
  if [[ -n ${VOXEL_CP_IMAGE:-} ]]; then
    printf '%s\n' "$VOXEL_CP_IMAGE"
    return 0
  fi
  names=$(zfs list -H -o name -r "$dataset/img" | awk -F/ '$NF ~ /^voxel-cp-/ { print $NF }')
  count=$(printf '%s' "$names" | grep -c . || true)
  if (( count == 0 )); then
    log "no voxel-cp image under $dataset/img; step 80 builds one" >&2
    exit 1
  elif (( count > 1 )); then
    log "more than one voxel-cp image under $dataset/img: $(printf '%s\n' "$names" | paste -sd' ' -); set VOXEL_CP_IMAGE" >&2
    exit 1
  fi
  printf '%s\n' "$names"
}

mode=${VOXEL_EXTERNAL_MODE:-lan}
if [[ $mode == isolated && -z ${VOXEL_EXTERNAL_UPLINK:-} ]]; then
  log "VOXEL_EXTERNAL_UPLINK is required in isolated mode"
  exit 1
fi

keys=(topology.sleds topology.sled_memory_gb image.cp image.frr external.mode)
values=("$VOXEL_SLEDS" "$VOXEL_SLED_MEMORY_GB" "$(cp_image)" voxel-frr-proto "$mode")
if [[ $mode == isolated ]]; then
  keys+=(external.uplink)
  values+=("$VOXEL_EXTERNAL_UPLINK")
fi
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
