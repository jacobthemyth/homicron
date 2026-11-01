#!/bin/bash
#
# Shared helpers for host steps. Each step defines check() and apply(),
# then calls step_main.
#
#   check    exit 0 when the end state already holds
#   apply    make it so; may `exit 10` to request a reboot
#
# step_main: check -> done; else apply, then check again -> 0 or 1.

log() {
  printf 'homicron: %s\n' "$*"
}

as_user() {
  su - "$HOMICRON_USER" -c "$*"
}

step_main() {
  if check; then
    log "already in the desired state"
    exit 0
  fi
  apply
  if check; then
    log "done"
    exit 0
  fi
  log "end state not reached after apply"
  exit 1
}
