#!/bin/bash
#
# Step 10: the login account.
#
# End state: $HOMICRON_USER exists with uid $HOMICRON_UID and home on
# rpool/home/$HOMICRON_USER, holds the Primary Administrator profile and the
# net_icmpaccess privilege, has the repository's authorized_keys, root has
# the same authorized_keys (the runner logs in as root), /etc/default/login
# puts /opt/ooce on the PATH, and /etc/default/su gives shells started with
# `su -` (as_user in lib.sh) the same PATH; su does not read login's, and
# its built-in default is a bare /usr/bin: with the current directory on it.
#
set -o errexit -o pipefail -o nounset
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

etc=${HOMICRON_ETC:-/etc}
home_root=${HOMICRON_HOME:-/home}
root_home=${HOMICRON_ROOT_HOME:-/root}
user=$HOMICRON_USER
home="$home_root/$user"
real_home="/home/$user"
dataset="rpool/home/$user"
keys_src="$HOMICRON_DIR/authorized_keys"
login_defaults="$etc/default/login"
su_defaults="$etc/default/su"
ooce_path='/opt/ooce/bin:/opt/ooce/sbin'

# The value of the active PATH= line in a defaults file, or nothing.
path_value() {
  sed -n 's/^PATH=//p' "$1" | tail -1
}

# Make the active PATH= line in a defaults file read exactly $2. Three
# shapes of file: an active PATH= line (replace it), only the stock commented
# #PATH= line (uncomment and replace), or neither (add one).
set_path() {
  local file=$1 value=$2
  if grep -q '^PATH=' "$file"; then
    awk -v v="$value" '/^PATH=/ { $0 = "PATH=" v } { print }' "$file" > "$file.homicron"
  elif grep -q '^#PATH=' "$file"; then
    awk -v v="$value" '/^#PATH=/ && !done { $0 = "PATH=" v; done = 1 } { print }' "$file" > "$file.homicron"
  else
    { cat "$file"; printf 'PATH=%s\n' "$value"; } > "$file.homicron"
  fi
  mv "$file.homicron" "$file"
}

user_exists() {
  local line
  line=$(getent passwd "$user" 2>/dev/null) || return 1
  [[ $(cut -d: -f3 <<< "$line") == "$HOMICRON_UID" ]]
}

dataset_exists() {
  zfs list -H -o name "$dataset" >/dev/null 2>&1
}

# Both readers are awk programs that consume the whole listing. `grep -q`
# would exit at the first match, and under pipefail a producer still writing
# then dies of SIGPIPE and fails the pipeline at random.
has_profile() {
  # profiles(1) prints a "user:" header and indents each profile name.
  profiles "$user" 2>/dev/null | awk '{ sub(/^[[:space:]]*/, "") } $0 == "Primary Administrator" { found = 1 } END { exit !found }'
}

has_icmp_priv() {
  userattr defaultpriv "$user" 2>/dev/null | awk '/net_icmpaccess/ { found = 1 } END { exit !found }'
}

# A line that is not blank and not a comment is a key, indented or not.
keys_present() {
  grep -Eq '^[[:space:]]*[^#[:space:]]' "$keys_src"
}

keys_match() {
  cmp -s "$keys_src" "$home/.ssh/authorized_keys" 2>/dev/null
}

root_keys_match() {
  cmp -s "$keys_src" "$root_home/.ssh/authorized_keys" 2>/dev/null
}

path_has_ooce() {
  grep -q "^PATH=.*/opt/ooce/bin" "$login_defaults"
}

su_path_matches_login() {
  [[ -n $(path_value "$login_defaults") && $(path_value "$su_defaults") == "$(path_value "$login_defaults")" ]]
}

check() {
  user_exists && dataset_exists && has_profile && has_icmp_priv && keys_match && root_keys_match && path_has_ooce && su_path_matches_login
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
    # The three paths this step creates; the home itself is a root-owned
    # ZFS mountpoint until now. Not -R: the home grows large.
    chown "$user:staff" "$home" "$home/.ssh" "$home/.ssh/authorized_keys"
  fi

  if ! root_keys_match; then
    log "installing authorized_keys for root"
    mkdir -p "$root_home/.ssh"
    cp "$keys_src" "$root_home/.ssh/authorized_keys"
    chmod 0700 "$root_home/.ssh"
    chmod 0600 "$root_home/.ssh/authorized_keys"
  fi

  if ! path_has_ooce; then
    log "adding $ooce_path to PATH in $login_defaults"
    # Start from the active line, else the stock commented one, else a
    # default. A trailing colon means the current directory; drop it.
    local base
    base=$(path_value "$login_defaults")
    [[ -n $base ]] || base=$(sed -n 's/^#PATH=//p' "$login_defaults" | head -1)
    [[ -n $base ]] || base=/usr/bin:/usr/sbin
    set_path "$login_defaults" "${base%:}:$ooce_path"
  fi

  if ! su_path_matches_login; then
    log "setting PATH in $su_defaults to match $login_defaults"
    set_path "$su_defaults" "$(path_value "$login_defaults")"
  fi
}

# An empty keys file would lock root and the user out. Refuse before check.
if ! keys_present; then
  log "$keys_src has no key; refusing to change $user or root"
  exit 1
fi

step_main
