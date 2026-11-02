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
  local link parts
  IFS=, read -r -a parts <<< "${MGMT_LINKS:-}"
  for link in "${parts[@]}"; do
    [[ -n $link ]] && printf '%s\n' "$link"
  done
  return 0
}

# The link's line names option 3, alone or among other options.
has_line() {
  grep -Eq "^$1\.PARAM_IGNORE_LIST=([0-9]+,)*3(,[0-9]+)*$" "$defaults" 2>/dev/null
}

chrony_online() {
  [[ $(svcs -H -o state chrony 2>/dev/null) == online ]]
}

# The gateway of a default route whose interface is the link, if any.
default_route_via() {
  netstat -rn -f inet | awk -v l="$1" '$1 == "default" && $NF == l { print $2; found = 1 } END { exit !found }'
}

mgmt_default_route() {
  local link
  for link in $(links); do
    default_route_via "$link" >/dev/null && return 0
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

recycle() {
  log "recycling the lease on $1, an ssh on it drops"
  ipadm delete-addr "$1/v4"
  ipadm create-addr -T dhcp -w 20 "$1/v4"
}

apply() {
  local link gateway
  if ! chrony_online; then
    log "enabling chrony"
    svcadm enable -s chrony
  fi
  for link in $(links); do
    if ! has_line "$link"; then
      {
        printf '\n# homicron: %s is management only and takes no default route from DHCP.\n' "$link"
        printf '%s.PARAM_IGNORE_LIST=3\n' "$link"
      } >> "$defaults"
      recycle "$link"
    elif gateway=$(default_route_via "$link"); then
      # The line is there but the lease that installed the route predates
      # it, or someone wrote the line by hand. A new lease drops the route.
      log "$link still holds a default route via $gateway although its dhcpagent line is present"
      recycle "$link"
    fi
  done
}

step_main
