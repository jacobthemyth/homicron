#!/bin/bash
#
# Stop method of svc:/site/voxel-rack:default: destroy the rack. A disabled
# service means no rack, and a host shutdown runs this before the VMs would
# die with the host. SMF kills anything left in the contract afterwards.
#
set -o nounset -o pipefail

dir=${HOMICRON_DIR:-/opt/homicron}
home_root=${HOMICRON_HOME:-/home}
log=${HOMICRON_RACK_LOG:-/var/log/voxel-rack.log}

say() {
  printf '%s\n' "$*" >> "$log"
}

[[ -r $dir/host.env ]] || exit 0

set -o allexport
# shellcheck disable=SC1091
source "$dir/host.env"
set +o allexport
[[ -n ${HOMICRON_USER:-} ]] || exit 0

voxel="$home_root/$HOMICRON_USER/src/voxel/target/release/voxel"
config="$home_root/$HOMICRON_USER/.config/voxel"

if [[ -d $config/.falcon ]]; then
  say "=== stop $(date -u '+%Y-%m-%dT%H:%M:%SZ'): destroying the rack"
  su - "$HOMICRON_USER" -c "pfexec $voxel destroy" < /dev/null >> "$log" 2>&1 || say "destroy exited $?"
fi
exit 0
