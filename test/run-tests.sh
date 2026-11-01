#!/bin/bash
#
# Run every bats test. Extra arguments are passed to bats.
#
set -o errexit -o pipefail -o nounset
cd "$(dirname "$0")/.."
exec bats -r test/ "$@"
