#!/bin/bash
#
# Step 25: network layout and time.
#
# End state: chrony is online, and every link in MGMT_LINKS has the line
# <link>.PARAM_IGNORE_LIST=3 in /etc/default/dhcpagent and no default route.
# Option 3 is Router: dhcpagent then leaves the default route to the other
# links, so a management port and the voxel uplink can share one LAN
# without two default routes. dhcpagent reads the file when a lease starts,
# so a link whose line is new gets its lease recycled.
#
# The step only adds lines. A link removed from MGMT_LINKS keeps its line
# until a person deletes it.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

defaults=${HOMICRON_DHCPAGENT_DEFAULTS:-/etc/default/dhcpagent}

# The management links, one per line, with empty elements dropped.
links() {
  local link
  IFS=, read -r -a parts <<< "${MGMT_LINKS:-}"
  for link in "${parts[@]}"; do
    [[ -n $link ]] && printf '%s\n' "$link"
  done
  return 0
}

has_line() {
  grep -qx "$1.PARAM_IGNORE_LIST=3" "$defaults" 2>/dev/null
}

chrony_online() {
  [[ $(svcs -H -o state chrony 2>/dev/null) == online ]]
}

# A default route whose interface is a management link.
mgmt_default_route() {
  local link
  for link in $(links); do
    if netstat -rn -f inet | awk -v l="$link" '$1 == "default" && $NF == l { found = 1 } END { exit !found }'; then
      return 0
    fi
  done
  return 1
}

check() {
  local link
  chrony_online || return 1
  for link in $(links); do
    has_line "$link" || return 1
  done
  ! mgmt_default_route
}

apply() {
  local link
  if ! chrony_online; then
    log "enabling chrony"
    svcadm enable -s chrony
  fi
  for link in $(links); do
    has_line "$link" && continue
    log "recycling the lease on $link, an ssh on it drops"
    {
      printf '\n# homicron: %s is management only and takes no default route from DHCP.\n' "$link"
      printf '%s.PARAM_IGNORE_LIST=3\n' "$link"
    } >> "$defaults"
    ipadm delete-addr "$link/v4"
    ipadm create-addr -T dhcp -w 20 "$link/v4"
  done
}

step_main
