#!/bin/bash
#
# Step 80: the voxel images.
#
# End state: `voxel image list` as $HOMICRON_USER shows a control plane image
# (voxel-cp-<omicron commit>) and the frr proto image (voxel-frr-proto).
# Each build takes 15 to 25 minutes and runs only when its image is
# missing, so a failed second build does not redo the first.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

home_root=${HOMICRON_HOME:-/home}
voxel="$home_root/$HOMICRON_USER/src/voxel/target/release/voxel"

# Image names, one per line: the first column of the table after its header.
# The row for the image that image.cp names starts with a * marker; the name
# is then the second column. The footer `* = current image.cp` is skipped.
images() {
  as_user "$voxel image list" | awk 'NR > 3 && NF && !($1 == "*" && $2 == "=") { print ($1 == "*") ? $2 : $1 }'
}

# awk reads every name. `grep -q` would exit at the first match, and under
# pipefail the producer then dies of SIGPIPE and fails the pipeline at random.
have_cp() {
  images | awk '/^voxel-cp-/ { found = 1 } END { exit !found }'
}

have_frr() {
  images | awk '$0 == "voxel-frr-proto" { found = 1 } END { exit !found }'
}

check() {
  have_cp && have_frr
}

apply() {
  if ! have_cp; then
    log "building the control plane image"
    as_user "pfexec $voxel image create"
  fi
  if ! have_frr; then
    log "building the frr proto image"
    as_user "pfexec $voxel image create-frr proto"
  fi
}

step_main
