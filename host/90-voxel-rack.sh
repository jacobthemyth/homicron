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
want=${VOXEL_RACK:-yes}
if [[ $want != yes && $want != no ]]; then
  log "VOXEL_RACK must be yes or no, not $want"
  exit 1
fi

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
    if [[ $want == no ]]; then
      svcadm disable "$fmri"
      log "voxel-rack disabled; the rack is destroyed"
    elif [[ $(state) == maintenance ]]; then
      # The instance is enabled already; enable would be a no-op. clear
      # restarts the method, which destroys and relaunches the rack.
      svcadm clear "$fmri"
      log "voxel-rack cleared; the launch retries under svc:/site/voxel-rack, log /var/log/voxel-rack.log"
    else
      svcadm enable "$fmri"
      log "voxel-rack enabled; the launch runs under svc:/site/voxel-rack, log /var/log/voxel-rack.log"
    fi
    wait_for_enabled "$want"
  fi
}

# svcadm returns before startd has moved the instance, so the check that
# follows apply could read the old state. Wait up to ten seconds for it.
wait_for_enabled() {
  local i
  for (( i = 0; i < 40; i++ )); do
    [[ $(enabled) == "$1" ]] && return 0
    sleep 0.25
  done
  return 0
}

step_main
