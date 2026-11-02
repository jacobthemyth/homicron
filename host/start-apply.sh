#!/bin/bash
#
# Start an apply on the box. Called once over ssh by bin/homicron after the
# rsync: makes sure the state dataset exists, installs and imports the
# service manifest, writes the marker that apply.sh looks for, and starts
# svc:/site/homicron-apply according to its state. Prints one line saying
# what it did.
#
# The state directory (marker and apply.log) is its own dataset,
# rpool/homicron, outside the boot environment: pkg update clones the root
# before step 30 asks for a reboot, so anything written to the root after
# the clone is absent in the new boot environment.
#
#   exit 0  started, or an apply was already running
#   exit 1  the service is in a state this script does not handle
#   exit 2  the manifest failed svccfg validate; nothing was changed
#
set -o errexit -o nounset -o pipefail

dir=${HOMICRON_DIR:-/opt/homicron}
state_dir=${HOMICRON_STATE_DIR:-/var/homicron}
manifest_dir=${HOMICRON_MANIFEST_DIR:-/lib/svc/manifest/site}
fmri=site/homicron-apply
manifest="$dir/homicron-apply.xml"
installed="$manifest_dir/homicron-apply.xml"
marker="$state_dir/apply-requested"

state() {
  local out
  out=$(svcs -H -o state "$fmri" 2>/dev/null | awk '{ print $1 }')
  printf '%s\n' "${out:-missing}"
}

# svcadm returns before startd has moved the instance. Wait until the state
# differs from what it was, so the watcher cannot read the old settled state
# and call the run finished before it started.
wait_for_change() {
  local old="$1" i
  for (( i = 0; i < 40; i++ )); do
    [[ $(state) != "$old" ]] && return 0
    sleep 0.25
  done
  return 0
}

dataset=rpool/homicron
ensure_state_dataset() {
  if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
    zfs create -o mountpoint="$state_dir" "$dataset"
  fi
}

boot_time() {
  kstat -p unix:0:system_misc:boot_time 2>/dev/null | awk '{ print $2 }'
}

if ! out=$(svccfg validate "$manifest" 2>&1); then
  printf '%s\n' "$out"
  exit 2
fi

ensure_state_dataset
mkdir -p "$manifest_dir" "$state_dir"
cp "$manifest" "$installed"
svccfg import "$installed"

# Write the marker, then run the svcadm verb. The marker must exist before
# the method starts, and must not outlive a svcadm that failed.
start_with() {
  boot_time > "$marker"
  if ! svcadm "$1" "$fmri"; then
    rm -f "$marker"
    echo "svcadm $1 $fmri failed"
    exit 1
  fi
}

current=$(state)
case $current in
  offline|offline\*|*\*)
    # A run is pending or in progress. The marker makes a pending boot-time
    # run do the apply rather than exit at once.
    boot_time > "$marker"
    echo "an apply is already running on the box"
    ;;
  maintenance)
    start_with clear
    wait_for_change "$current"
    echo "cleared the failed run and started"
    ;;
  disabled|uninitialized|missing)
    start_with enable
    wait_for_change "$current"
    echo "enabled and started"
    ;;
  online)
    start_with restart
    wait_for_change "$current"
    echo "restarted"
    ;;
  *)
    echo "service is in state $current; not started"
    exit 1
    ;;
esac
