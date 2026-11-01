#!/bin/bash
#
# Build the site into _site/ and serve it over plain HTTP for testing
# install.sh before anything is pushed.
#
#   test/serve.sh [PORT]    default 8000
#
# From a qemu guest on user-mode networking the host is 10.0.2.2, so:
#   curl -fsSL http://10.0.2.2:8000/install | HOMICRON_BASE_URL=http://10.0.2.2:8000 bash -s -- vm c1t0d0
#
set -o errexit -o pipefail -o nounset

root=$(cd "$(dirname "$0")/.." && pwd)
port=${1:-8000}

"$root/pages/build-site.sh" "$root/_site"
exec python3 -m http.server --directory "$root/_site" --bind 0.0.0.0 "$port"
