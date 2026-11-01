#!/bin/bash
#
# Run one host step on the box with its environment loaded and its output
# logged. Called over ssh by bin/homicron.
#
#   run-step.sh <NN-name.sh>
#
set -o errexit -o pipefail -o nounset

dir=${HOMICRON_DIR:-/opt/homicron}
log_dir=${HOMICRON_LOG_DIR:-/var/log/homicron}

step=${1:?usage: run-step.sh <step.sh>}

set -o allexport
# shellcheck disable=SC1091
source "$dir/host.env"
set +o allexport
export HOMICRON_DIR="$dir"

mkdir -p "$log_dir"
log="$log_dir/$step.log"
printf '=== %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$step" >> "$log"

status=0
bash "$dir/$step" 2>&1 | tee -a "$log" || status=${PIPESTATUS[0]}
exit "$status"
