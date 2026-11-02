#!/bin/bash
#
# Start an apply on the box. Called once over ssh by bin/homicron after the
# rsync: installs and imports the service manifest, writes the marker that
# apply.sh looks for, and starts svc:/site/homicron-apply according to its
# state. Prints one line saying what it did.
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
  svcs -H -o state "$fmri" 2>/dev/null || echo missing
}

boot_time() {
  kstat -p unix:0:system_misc:boot_time 2>/dev/null | awk '{ print $2 }'
}

if ! out=$(svccfg validate "$manifest" 2>&1); then
  printf '%s\n' "$out"
  exit 2
fi

mkdir -p "$manifest_dir" "$state_dir"
cp "$manifest" "$installed"
svccfg import "$installed"
boot_time > "$marker"

current=$(state)
case $current in
  offline\*)
    echo "an apply is already running on the box"
    ;;
  maintenance)
    svcadm clear "$fmri"
    echo "cleared the failed run and started"
    ;;
  disabled|uninitialized|missing)
    svcadm enable "$fmri"
    echo "enabled and started"
    ;;
  online)
    svcadm restart "$fmri"
    echo "restarted"
    ;;
  *)
    echo "service is in state $current; not started"
    exit 1
    ;;
esac
