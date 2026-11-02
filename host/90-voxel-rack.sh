#!/bin/bash
#
# Step 90: the rack service.
#
# End state: /lib/svc/manifest/site/voxel-rack.xml matches the shipped
# host/voxel-rack.xml, svc:/site/voxel-rack:default is imported, and it is
# enabled when VOXEL_RACK is yes and disabled otherwise. The two method
# scripts need no install of their own: the runner's rsync puts every file
# in host/ under /opt/homicron, which is where the manifest points.
#
# Enabling starts the launch at once on a running box, as well as at every
# boot. The step does not wait for it: svcs -xv site/voxel-rack and
# /var/log/voxel-rack.log show how it went. Disabling destroys a running
# rack.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

dir=${HOMICRON_DIR:-/opt/homicron}
manifest_dir=${HOMICRON_MANIFEST_DIR:-/lib/svc/manifest/site}
fmri=site/voxel-rack
manifest="$dir/voxel-rack.xml"
installed="$manifest_dir/voxel-rack.xml"
want=$([[ ${VOXEL_RACK:-yes} == yes ]] && echo yes || echo no)

state() {
  local out
  out=$(svcs -H -o state "$fmri" 2>/dev/null | awk '{ print $1 }')
  printf '%s\n' "${out:-missing}"
}

# online, offline, and offline* (the method is running) are all enabled.
enabled() {
  case $(state) in
    online|offline|offline\*) echo yes ;;
    *) echo no ;;
  esac
}

manifest_installed() {
  [[ -f $installed ]] && cmp -s "$manifest" "$installed"
}

check() {
  manifest_installed && [[ $(state) != missing ]] && [[ $(enabled) == "$want" ]]
}

apply() {
  local out
  if ! manifest_installed; then
    if ! out=$(svccfg validate "$manifest" 2>&1); then
      log "svccfg validate $manifest failed:"
      printf '%s\n' "$out"
      exit 1
    fi
    mkdir -p "$manifest_dir"
    cp "$manifest" "$installed"
    svccfg import "$installed"
  fi
  if [[ $(enabled) != "$want" ]]; then
    if [[ $want == yes ]]; then
      svcadm enable "$fmri"
      log "voxel-rack enabled; the launch runs under svc:/site/voxel-rack, log /var/log/voxel-rack.log"
    else
      svcadm disable "$fmri"
      log "voxel-rack disabled; the rack is destroyed"
    fi
  fi
}

step_main
