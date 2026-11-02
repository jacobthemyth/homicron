#!/bin/bash
#
# Stream apply.log to the runner until svc:/site/homicron-apply settles.
# Called over ssh by bin/homicron as
#
#   watch-apply.sh <lines-already-seen> <max-seconds>
#
# Prints the log lines after the offset as they appear, polling once a
# second while the method runs, and exits
#
#   0  online: the apply converged
#   1  maintenance: a step failed
#   3  any other settled state (printed as "service is <state>")
#   4  still running after <max-seconds>
#
# The runner counts the lines it received, so a reconnect after a reboot or
# a dropped connection passes the count back and no line is shown twice.
#
set -o nounset -o pipefail

log_dir=${HOMICRON_LOG_DIR:-/var/log/homicron}
log="$log_dir/apply.log"
fmri=site/homicron-apply

seen=${1:?usage: watch-apply.sh <lines-already-seen> <max-seconds>}
max=${2:?usage: watch-apply.sh <lines-already-seen> <max-seconds>}
waited=0

while true; do
  total=0
  if [[ -r $log ]]; then
    total=$(wc -l < "$log")
    total=${total// /}
  fi
  if (( total > seen )); then
    sed -n "$((seen + 1)),\$p" "$log"
    seen=$total
  fi
  state=$(svcs -H -o state "$fmri" 2>/dev/null || echo missing)
  case $state in
    offline\*|missing)
      if (( waited >= max )); then
        exit 4
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
