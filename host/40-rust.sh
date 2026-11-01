#!/bin/bash
#
# Step 40: a Rust toolchain for $HOMICRON_USER.
#
# End state: ~/.cargo/bin/cargo runs for the user.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

check() {
  # The tilde expands in the user's own shell under su -c.
  # shellcheck disable=SC2088
  as_user '~/.cargo/bin/cargo --version' >/dev/null 2>&1
}

apply() {
  log "installing rustup for $HOMICRON_USER"
  as_user "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y --profile minimal"
}

step_main
