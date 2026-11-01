#!/bin/bash
#
# Step 30: pkg update and the build tools.
#
# End state: `pkg update -n` reports nothing to do (exit 4) and the three
# developer packages are installed. Whenever a boot environment is active on
# reboot but not now (pkg created and activated one), exit 10 so the runner
# reboots and runs this step again.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

packages=(
  developer/build-essential
  developer/illumos-tools
  developer/versioning/git
)

nothing_to_update() {
  local status=0
  pkg update -n >/dev/null 2>&1 || status=$?
  (( status == 4 ))
}

packages_installed() {
  pkg list -H "${packages[@]}" >/dev/null 2>&1
}

# `beadm list -H` fields: name;uuid;active;mountpoint;space;policy;created.
# The active flags are N (now), R (on reboot), or both. A boot environment
# with R and no N is activated but not yet booted: a reboot is pending. A
# backup BE that pkg creates without activating has neither flag.
reboot_pending() {
  beadm list -H 2>/dev/null | awk -F';' '$3 ~ /R/ && $3 !~ /N/ { found = 1 } END { exit !found }'
}

request_reboot_if_pending() {
  if reboot_pending; then
    log "$1"
    exit 10
  fi
}

check() {
  nothing_to_update && packages_installed
}

apply() {
  local status=0
  request_reboot_if_pending "a boot environment is already activated for the next boot; reboot required"

  # pkg update refuses to run while pkg(7) itself is out of date.
  log "updating pkg(7)"
  pkg install -v pkg:/package/pkg || status=$?
  if (( status != 0 && status != 4 )); then
    log "pkg install pkg:/package/pkg failed with status $status"
    exit "$status"
  fi
  request_reboot_if_pending "pkg(7) update created a new boot environment; reboot required"
  status=0

  log "pkg update"
  pkg update -v || status=$?
  case $status in
    0) ;;
    4)
      log "no updates available"
      ;;
    *)
      log "pkg update failed with status $status"
      exit "$status"
      ;;
  esac
  request_reboot_if_pending "update created a new boot environment; reboot required"

  if ! packages_installed; then
    log "installing ${packages[*]}"
    status=0
    pkg install -v "${packages[@]}" || status=$?
    if (( status != 0 && status != 4 )); then
      log "pkg install failed with status $status"
      exit "$status"
    fi
    request_reboot_if_pending "package install created a new boot environment; reboot required"
  fi
}

step_main
