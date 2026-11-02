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
# reboot interrupted resumes. The marker and apply.log live in the state
# directory, a dataset outside the boot environment (see start-apply.sh);
# the per-step logs stay under /var/log/homicron.
#
# Exit codes are SMF's: 95 (SMF_EXIT_ERR_FATAL) puts the service straight
# into maintenance when a step fails, 96 (SMF_EXIT_ERR_CONFIG) when host.env
# is missing. A plain 1 would make startd retry the method.
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
log="$state_dir/apply.log"
smf_exit_err_fatal=95
smf_exit_err_config=96

say() {
  printf '%s\n' "$*" >> "$log"
}

boot_time() {
  kstat -p unix:0:system_misc:boot_time 2>/dev/null | awk '{ print $2 }'
}

[[ -e $marker ]] || exit 0

mkdir -p "$log_dir" "$state_dir"

if [[ ! -r $dir/host.env ]]; then
  say "host.env missing in $dir; nothing run"
  exit "$smf_exit_err_config"
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
      exit "$smf_exit_err_fatal"
    fi
    printf '%s %s\n' "$now_boot" "$step" > "$marker"
    say "rebooting for $step"
    # watch-apply.sh polls once a second; let it read the line before the
    # reboot kills it along with sshd.
    sleep 3
    reboot
    exit 0
  elif (( status != 0 )); then
    say "step $step failed with status $status"
    exit "$smf_exit_err_fatal"
  fi
done

rm -f "$marker"
say "apply complete"
exit 0
