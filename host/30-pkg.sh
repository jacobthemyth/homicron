#!/bin/bash
#
# Step 30: pkg update and the build tools.
#
# End state: `pkg update -n` reports nothing to do (exit 4) and the three
# developer packages are installed. If the update creates a new boot
# environment, exit 10 so the runner reboots and runs this step again.
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

boot_environments() {
  beadm list -H 2>/dev/null | cut -d';' -f1 | sort
}

check() {
  nothing_to_update && packages_installed
}

apply() {
  local before after status=0
  before=$(boot_environments)

  log "pkg update"
  pkg update -v || status=$?
  case $status in
    0)
      after=$(boot_environments)
      if [[ $before != "$after" ]]; then
        log "update created a new boot environment; reboot required"
        exit 10
      fi
      ;;
    4)
      log "no updates available"
      ;;
    *)
      log "pkg update failed with status $status"
      exit "$status"
      ;;
  esac

  if ! packages_installed; then
    log "installing ${packages[*]}"
    status=0
    pkg install -v "${packages[@]}" || status=$?
    if (( status != 0 && status != 4 )); then
      log "pkg install failed with status $status"
      exit "$status"
    fi
  fi
}

step_main
