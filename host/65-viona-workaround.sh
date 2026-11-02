#!/bin/bash
#
# Step 65: viona workaround for falcon issue 383.
#
# The propolis that voxel's pinned falcon builds against mishandles the ring
# event-index feature that the viona driver in current Helios advertises. A
# Linux guest with a virtio NIC then freezes as soon as it brings the NIC up,
# which stops `voxel image create-frr` at the Debian builder's login.
# Masking the feature in the host driver avoids it.
#   https://github.com/oxidecomputer/falcon/issues/383
#
# End state: /etc/system carries the mask line, so it survives a reboot, and
# the running kernel already has the mask, so no reboot is needed now.
#
# The workaround was validated with voxel at $validated_commit. When the
# checkout is at any other commit the step logs a warning: once voxel pins a
# falcon whose propolis is at or past 6588611, remove the line.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

etc=${HOMICRON_ETC:-/etc}
home_root=${HOMICRON_HOME:-/home}
system_file="$etc/system"
src="$home_root/$HOMICRON_USER/src/voxel"
line='set viona:viona_feat_disable_mask=0x20000000'
mask=20000000
validated_commit=77901ac4bb2d6e1ac6dd7380b3758129b73f69cd
issue=https://github.com/oxidecomputer/falcon/issues/383

file_has_line() {
  grep -qxF "$line" "$system_file" 2>/dev/null
}

# mdb prints the symbol name on one line and "name: value" on the next; the
# value is hex without a prefix.
live_mask() {
  echo 'viona_feat_disable_mask/X' | mdb -k 2>/dev/null | awk 'END { print $2 }'
}

live_ok() {
  [[ $(live_mask) == "$mask" ]]
}

check() {
  file_has_line && live_ok
}

apply() {
  if ! file_has_line; then
    log "adding the viona mask to $system_file"
    # Start on a new line even when the file lacks a trailing newline.
    if [[ -s $system_file && -n $(tail -c 1 "$system_file") ]]; then
      printf '\n' >> "$system_file"
    fi
    printf '* homicron: viona workaround for %s\n%s\n' "$issue" "$line" >> "$system_file"
  fi
  if ! live_ok; then
    log "setting the live viona mask"
    echo "viona_feat_disable_mask/Z 0x$mask" | mdb -kw >/dev/null
  fi
}

# The warning does not change the end state; it tells the operator when to
# revisit the workaround.
if [[ -d $src/.git ]]; then
  head=$(as_user "cd $src && git rev-parse HEAD" 2>/dev/null || true)
  if [[ -n $head && $head != "$validated_commit" ]]; then
    log "warning: VOXEL_REF=$VOXEL_REF resolves to $head, not $validated_commit where the viona workaround was validated. Check $issue; once voxel pins a falcon with propolis at or past 6588611, remove '$line' from $system_file"
  fi
fi

step_main
