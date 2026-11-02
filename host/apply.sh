#!/bin/bash
#
# Start method of svc:/site/homicron-apply:default: run every host step in
# order on the box. bin/homicron ships host/ here, start-apply.sh writes the
# marker and starts the service, and watch-apply.sh streams the log back.
#
# The marker $HOMICRON_STATE_DIR/apply-requested holds the kernel boot time
# that start-apply.sh saw, and after a step asked for a reboot also that
# step's name. The method runs at every boot (SMF starts enabled transient
# services); without the marker it exits at once, so only an apply that a
# reboot interrupted resumes.
#
# Protocol lines in apply.log, read by bin/homicron:
#   === run <time>[ (resumed after reboot)]
#   ==> <step>
#   rebooting for <step>
#   step <step> failed with status <N>
#   apply complete
#
set -o nounset -o pipefail

dir=${HOMICRON_DIR:-/opt/homicron}
log_dir=${HOMICRON_LOG_DIR:-/var/log/homicron}
state_dir=${HOMICRON_STATE_DIR:-/var/homicron}
marker="$state_dir/apply-requested"
log="$log_dir/apply.log"

say() {
  printf '%s\n' "$*" >> "$log"
}

boot_time() {
  kstat -p unix:0:system_misc:boot_time 2>/dev/null | awk '{ print $2 }'
}

[[ -e $marker ]] || exit 0

mkdir -p "$log_dir"

if [[ ! -r $dir/host.env ]]; then
  say "host.env missing in $dir; nothing run"
  exit 1
fi

set -o allexport
# shellcheck disable=SC1091
source "$dir/host.env"
set +o allexport
export HOMICRON_DIR="$dir"

read -r marker_boot rebooted_for < "$marker"
rebooted_for=${rebooted_for:-}
now_boot=$(boot_time)
header="=== run $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [[ -n $now_boot && $marker_boot != "$now_boot" ]]; then
  header+=" (resumed after reboot)"
fi
say "$header"

for path in "$dir"/[0-9][0-9]-*.sh; do
  step=$(basename "$path")
  say "==> $step"
  step_log="$log_dir/$step.log"
  printf '=== %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$step" >> "$step_log"
  bash -x "$path" 2>&1 | tee -a "$step_log" >> "$log"
  status=${PIPESTATUS[0]}
  if (( status == 10 )); then
    if [[ $rebooted_for == "$step" ]]; then
      say "step $step failed with status 10 (asked for a second reboot)"
      exit 1
    fi
    printf '%s %s\n' "$now_boot" "$step" > "$marker"
    say "rebooting for $step"
    reboot
    exit 0
  elif (( status != 0 )); then
    say "step $step failed with status $status"
    exit 1
  fi
done

rm -f "$marker"
say "apply complete"
exit 0
