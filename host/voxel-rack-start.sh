#!/bin/bash
#
# Start method of svc:/site/voxel-rack:default: destroy the previous rack
# and launch a new one. A voxel rack does not survive a host reboot, and a
# plain `voxel launch` on the surviving topology fails in RSS, so every
# start begins from `voxel destroy`.
#
# Every voxel command runs as $HOMICRON_USER through pfexec, so the user's
# voxel.toml applies. The VMs that `voxel launch` starts are plain children
# of the launcher: SMF methods have no controlling terminal, so they live
# on after this method exits. Output goes to /var/log/voxel-rack.log.
#
# Exit codes are SMF's: 0 online, 95 (SMF_EXIT_ERR_FATAL) straight to
# maintenance when the launch fails, 96 (SMF_EXIT_ERR_CONFIG) when
# host.env is missing. A plain 1 would make startd retry the method.
#
set -o nounset -o pipefail

dir=${HOMICRON_DIR:-/opt/homicron}
home_root=${HOMICRON_HOME:-/home}
log=${HOMICRON_RACK_LOG:-/var/log/voxel-rack.log}
smf_exit_err_fatal=95
smf_exit_err_config=96

say() {
  printf '%s\n' "$*" >> "$log"
}

say "=== start $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ ! -r $dir/host.env ]]; then
  say "host.env missing in $dir; no launch"
  exit "$smf_exit_err_config"
fi

set -o allexport
# shellcheck disable=SC1091
source "$dir/host.env"
set +o allexport

if [[ -z ${HOMICRON_USER:-} ]]; then
  say "HOMICRON_USER missing in $dir/host.env; no launch"
  exit "$smf_exit_err_config"
fi

voxel="$home_root/$HOMICRON_USER/src/voxel/target/release/voxel"
config="$home_root/$HOMICRON_USER/.config/voxel"

# A voxel command as the user, with no terminal and its output in the log.
run_voxel() {
  su - "$HOMICRON_USER" -c "pfexec $voxel $*" < /dev/null >> "$log" 2>&1
}

if [[ -d $config/.falcon ]]; then
  say "destroying the previous rack"
  # A failed destroy is logged by voxel itself; launch's preflight reports
  # what is left better than this method can.
  run_voxel destroy || say "destroy exited $?"
fi

say "launching the rack"
capture=$(mktemp)
su - "$HOMICRON_USER" -c "pfexec $voxel launch" < /dev/null > "$capture" 2>&1
launch_status=$?
cat "$capture" >> "$log"
if ! grep -q 'launch complete' "$capture" || grep -q 'rack-init FAILED' "$capture"; then
  rm -f "$capture"
  say "launch failed; see above (voxel launch exited $launch_status)"
  exit "$smf_exit_err_fatal"
fi
rm -f "$capture"

hook="$config/post-launch.sh"
hook_timeout=${HOMICRON_HOOK_TIMEOUT:-600}
if [[ -x $hook ]]; then
  say "running $hook"
  # The VMs live in this method's contract. A hook that never returns would
  # hit the method timeout, and startd would kill the contract, rack and
  # all. So the hook gets its own, shorter bound.
  timeout "$hook_timeout" su - "$HOMICRON_USER" -c "$hook" < /dev/null >> "$log" 2>&1
  hook_status=$?
  if (( hook_status == 124 )); then
    say "post-launch.sh timed out after ${hook_timeout}s"
  else
    say "post-launch.sh exited $hook_status"
  fi
fi

say "rack up"
exit 0
