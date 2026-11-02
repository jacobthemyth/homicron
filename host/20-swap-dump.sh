#!/bin/bash
#
# Step 20: swap and crash dump zvols.
#
# End state: rpool/swap and rpool/dump exist, swap is active and in vfstab,
# and dumpadm points at the dump zvol.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

etc=${HOMICRON_ETC:-/etc}
vfstab="$etc/vfstab"
swap_zvol=rpool/swap
dump_zvol=rpool/dump
swap_dev="/dev/zvol/dsk/$swap_zvol"
dump_dev="/dev/zvol/dsk/$dump_zvol"
vfstab_line=$'/dev/zvol/dsk/rpool/swap\t-\t-\tswap\t-\tno\t-'

zvol_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

# The two readers are awk programs that consume the whole listing. `grep -q`
# would exit at the first match, and under pipefail a producer still writing
# then dies of SIGPIPE and fails the pipeline at random.
swap_active() {
  swap -l 2>/dev/null | awk -v dev="$swap_dev" '$1 == dev { found = 1 } END { exit !found }'
}

vfstab_has_swap() {
  grep -q -F "$swap_dev" "$vfstab"
}

dump_configured() {
  dumpadm 2>/dev/null | awk -v dev="$dump_dev" 'index($0, dev) { found = 1 } END { exit !found }'
}

check() {
  zvol_exists "$swap_zvol" && zvol_exists "$dump_zvol" && swap_active && vfstab_has_swap && dump_configured
}

apply() {
  if ! zvol_exists "$swap_zvol"; then
    log "creating $swap_zvol ($SWAP_SIZE)"
    zfs create -V "$SWAP_SIZE" "$swap_zvol"
  fi
  if ! zvol_exists "$dump_zvol"; then
    log "creating $dump_zvol ($DUMP_SIZE)"
    zfs create -V "$DUMP_SIZE" "$dump_zvol"
  fi
  if ! swap_active; then
    log "activating swap on $swap_dev"
    swap -a "$swap_dev"
  fi
  if ! vfstab_has_swap; then
    log "adding swap to $vfstab"
    printf '%s\n' "$vfstab_line" >> "$vfstab"
  fi
  if ! dump_configured; then
    log "pointing dumpadm at $dump_dev"
    dumpadm -d "$dump_dev"
  fi
}

step_main
