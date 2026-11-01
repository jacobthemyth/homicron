#!/bin/bash
#
# Step 50: the ZFS dataset voxel stores images and VM disks in.
#
# End state: $FALCON_DATASET exists. An empty FALCON_DATASET means voxel
# uses its rpool default and there is nothing to do.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

dataset=${FALCON_DATASET:-}

if [[ -z $dataset ]]; then
  log "FALCON_DATASET is empty; voxel will use the rpool default"
  exit 0
fi

check() {
  zfs list -H -o name "$dataset" >/dev/null 2>&1
}

apply() {
  log "creating $dataset"
  zfs create -p "$dataset"
}

step_main
