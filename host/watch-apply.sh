#!/bin/bash
#
# Stream apply.log to the runner until svc:/site/homicron-apply settles.
# Called over ssh by bin/homicron as
#
#   watch-apply.sh <lines-already-seen> <max-seconds>
#
# Prints the log lines after the offset as they appear, polling once a
# second while the method runs or is waiting for its dependencies (any
# `offline` state, or a transitional state marked with `*`), and exits
#
#   0  online: the apply converged
#   1  maintenance: a step failed
#   3  any other settled state (printed as "service is <state>")
#   4  still running after <max-seconds>
#   5  the ssh session ended (this script was reparented)
#
# The runner counts the lines it received, so a reconnect after a reboot or
# a dropped connection passes the count back and no line is shown twice.
#
set -o nounset -o pipefail

state_dir=${HOMICRON_STATE_DIR:-/var/homicron}
log="$state_dir/apply.log"
fmri=site/homicron-apply

seen=${1:?usage: watch-apply.sh <lines-already-seen> <max-seconds>}
max=${2:?usage: watch-apply.sh <lines-already-seen> <max-seconds>}
waited=0

# When the ssh client disconnects, the sshd session that started this script
# exits and the script is reparented to init. The loop below notices, so a
# runner that was killed does not leave this script polling for hours.
parent=$PPID

client_gone() {
  local now
  now=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
  [[ -n $now && $now != "$parent" ]]
}

while true; do
  total=0
  if [[ -r $log ]]; then
    total=$(wc -l < "$log")
    total=${total// /}
  fi
  # Exactly the counted range: a line still being written is left for the
  # next pass, so nothing is printed twice and the count stays in step.
  if (( total > seen )); then
    sed -n "$((seen + 1)),${total}p" "$log"
    seen=$total
  fi
  state=$(svcs -H -o state "$fmri" 2>/dev/null | awk '{ print $1 }')
  state=${state:-missing}
  case $state in
    offline|offline\*|*\*|missing)
      if (( waited >= max )); then
        exit 4
      fi
      if client_gone; then
        exit 5
      fi
      sleep 1
      waited=$((waited + 1))
      ;;
    online) exit 0 ;;
    maintenance) exit 1 ;;
    *)
      echo "service is $state"
      exit 3
      ;;
  esac
done
