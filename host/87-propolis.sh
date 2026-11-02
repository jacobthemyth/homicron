#!/bin/bash
#
# Step 87: the propolis-server binary for the rack's VMs.
#
# End state: /opt/homicron/propolis/<rev> exists with mode 0755 and the
# sha256 digest buildomat publishes for that rev, and voxel.toml names it
# in falcon.propolis_binary. falcon then skips its own download at launch,
# which stalled on 2026-11-02. The rev is the propolis-client rev pinned in
# the voxel workspace Cargo.toml, the same rev falcon would fetch.
#
# The directory is on the rpool/homicron state dataset, which start-apply.sh
# creates: outside /opt/homicron, which the runner's rsync --delete owns,
# outside the user's home, where `voxel destroy` deletes .falcon/bin, and
# outside the boot environment, so an OS update keeps it. Old revs are left
# in place.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

home_root=${HOMICRON_HOME:-/home}
src="$home_root/$HOMICRON_USER/src/voxel"
voxel="$src/target/release/voxel"
dir=${HOMICRON_PROPOLIS_DIR:-/var/homicron/propolis}
base=https://buildomat.eng.oxide.computer/public/file/oxidecomputer/propolis/falcon
curl_opts=(-fsSL --retry 5 --retry-all-errors)

rev() {
  sed -n -E 's/^propolis-client *=.*rev *= *"([0-9a-f]{40})".*/\1/p' "$src/Cargo.toml" | head -1
}

rev=$(rev)
if [[ -z $rev ]]; then
  log "cannot read the propolis rev from voxel's Cargo.toml"
  exit 1
fi
binary="$dir/$rev"
saved_digest="$binary.sha256"
url="$base/$rev/propolis-server"

file_digest() {
  digest -a sha256 "$1"
}

# `config get` prints a string value as a TOML literal, with its quotes.
configured() {
  as_user "$voxel config get falcon.propolis_binary" 2>/dev/null | sed -e 's/^"//' -e 's/"$//' || true
}

check() {
  [[ -x $binary && -f $saved_digest ]] || return 1
  [[ $(file_digest "$binary") == "$(cat "$saved_digest")" ]] || return 1
  [[ $(configured) == "$binary" ]]
}

apply() {
  local expected actual
  mkdir -p "$dir"
  if [[ ! -x $binary || ! -f $saved_digest || $(file_digest "$binary") != "$(cat "$saved_digest")" ]]; then
    log "downloading propolis-server $rev"
    expected=$(curl "${curl_opts[@]}" "$url.sha256.txt" | awk '{ print $1 }')
    curl "${curl_opts[@]}" -C - -o "$binary.part" "$url"
    actual=$(file_digest "$binary.part")
    if [[ $actual != "$expected" ]]; then
      rm -f "$binary.part"
      log "propolis-server digest $actual does not match the published $expected"
      exit 1
    fi
    mv "$binary.part" "$binary"
    chmod 0755 "$binary"
    printf '%s\n' "$expected" > "$saved_digest"
  fi
  if [[ $(configured) != "$binary" ]]; then
    log "voxel config set falcon.propolis_binary $binary"
    as_user "$voxel config set falcon.propolis_binary $binary"
  fi
}

step_main
