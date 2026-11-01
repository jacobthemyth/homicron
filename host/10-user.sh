#!/bin/bash
#
# Step 10: the login account.
#
# End state: $HOMICRON_USER exists with uid $HOMICRON_UID and home on
# rpool/home/$HOMICRON_USER, holds the Primary Administrator profile and the
# net_icmpaccess privilege, has the repository's authorized_keys, and
# /etc/default/login puts /opt/ooce on the PATH.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

etc=${HOMICRON_ETC:-/etc}
home_root=${HOMICRON_HOME:-/home}
user=$HOMICRON_USER
home="$home_root/$user"
real_home="/home/$user"
dataset="rpool/home/$user"
keys_src="$HOMICRON_DIR/authorized_keys"
login_defaults="$etc/default/login"
ooce_path='/opt/ooce/bin:/opt/ooce/sbin'

user_exists() {
  local line
  line=$(getent passwd "$user" 2>/dev/null) || return 1
  [[ $(cut -d: -f3 <<< "$line") == "$HOMICRON_UID" ]]
}

dataset_exists() {
  zfs list -H -o name "$dataset" >/dev/null 2>&1
}

has_profile() {
  # profiles(1) prints a "user:" header and indents each profile name.
  profiles "$user" 2>/dev/null | sed 's/^[[:space:]]*//' | grep -qx 'Primary Administrator'
}

has_icmp_priv() {
  userattr defaultpriv "$user" 2>/dev/null | grep -q 'net_icmpaccess'
}

keys_match() {
  cmp -s "$keys_src" "$home/.ssh/authorized_keys" 2>/dev/null
}

path_has_ooce() {
  grep -q "^PATH=.*/opt/ooce/bin" "$login_defaults"
}

check() {
  user_exists && dataset_exists && has_profile && has_icmp_priv && keys_match && path_has_ooce
}

apply() {
  if ! dataset_exists; then
    log "creating $dataset"
    zfs create -p -o mountpoint="$real_home" "$dataset"
  fi

  if ! user_exists; then
    log "creating user $user"
    useradd -u "$HOMICRON_UID" -g staff -d "$real_home" -s /bin/bash -P 'Primary Administrator' "$user"
    passwd -N "$user"
  elif ! has_profile; then
    log "granting Primary Administrator to $user"
    usermod -P 'Primary Administrator' "$user"
  fi

  if ! has_icmp_priv; then
    log "granting net_icmpaccess to $user"
    usermod -K defaultpriv=basic,net_icmpaccess "$user"
  fi

  if ! keys_match; then
    log "installing authorized_keys for $user"
    mkdir -p "$home/.ssh"
    cp "$keys_src" "$home/.ssh/authorized_keys"
    chmod 0700 "$home" "$home/.ssh"
    chmod 0600 "$home/.ssh/authorized_keys"
    chown -R "$user:staff" "$home"
  fi

  if ! path_has_ooce; then
    log "adding $ooce_path to PATH in $login_defaults"
    # Three shapes of file: an active PATH= line (append to it), only the
    # stock commented #PATH= line (uncomment and append), or neither (add one).
    if grep -q '^PATH=' "$login_defaults"; then
      awk -v extra="$ooce_path" '/^PATH=/ { $0 = $0 ":" extra } { print }' "$login_defaults" > "$login_defaults.homicron"
    elif grep -q '^#PATH=' "$login_defaults"; then
      awk -v extra="$ooce_path" '/^#PATH=/ && !done { sub(/^#/, ""); $0 = $0 extra; done = 1 } { print }' "$login_defaults" > "$login_defaults.homicron"
    else
      { cat "$login_defaults"; printf 'PATH=/usr/bin:/usr/sbin:%s\n' "$ooce_path"; } > "$login_defaults.homicron"
    fi
    mv "$login_defaults.homicron" "$login_defaults"
  fi
}

step_main
