#!/bin/bash
#
# homicron stage 1. Runs in the Helios installer ramdisk, as root.
#
#   ipadm create-addr -T dhcp <nic>/v4 && \
#     echo "nameserver $(dhcpinfo -i <nic> DNSserv)" > /etc/resolv.conf && \
#     curl -fsSLo /tmp/i https://homicron.smithjs.org/install && \
#     HOMICRON_KEYS_URL=https://github.com/<user>.keys bash /tmp/i <hostname> <disk>...
#
# Fetches the public keys from HOMICRON_KEYS_URL, runs install-helios, then
# seeds the new root (still mounted at /a) with those keys, the first-boot
# service, the dhcpagent DNS hook, the ramdisk's working resolv.conf, and
# /etc/homicron.conf. Does not reboot.
#
set -o errexit -o pipefail -o nounset

base_url=${HOMICRON_BASE_URL:-https://homicron.smithjs.org}
keys_url=${HOMICRON_KEYS_URL:-}
altroot=${HOMICRON_ALTROOT:-/a}
install_helios=${HOMICRON_INSTALL_HELIOS:-/usr/bin/install-helios}
ramdisk_resolv=${HOMICRON_RESOLV_CONF:-/etc/resolv.conf}

usage() {
  printf 'usage: install <hostname> <disk> [<disk> [<disk>]]\n' >&2
  printf '  one disk: single; two: mirror; three: raidz1\n' >&2
  printf '  HOMICRON_KEYS_URL=<url> is required: a URL that serves your public keys, one per line\n' >&2
  printf '  for example https://github.com/<user>.keys\n' >&2
  exit 2
}

fail() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

sum_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# A key line has a key type field followed by a base64 field, after any
# options such as from="...". sshd accepts sk- types and ecdsa- types too.
type_re='^(sk-)?(ssh|ecdsa)-[A-Za-z0-9.@-]+$'
# Every OpenSSH blob starts with AAAA: the base64 of the length prefix.
blob_re='^AAAA[A-Za-z0-9+/]+=*$'

is_key_line() {
  local -a f
  local i
  read -r -a f <<< "$1"
  for (( i = 0; i + 1 < ${#f[@]}; i++ )); do
    if [[ ${f[i]} =~ $type_re && ${f[i+1]} =~ $blob_re ]]; then
      return 0
    fi
  done
  return 1
}

# Every line must be blank, a comment, or a key, and at least one must be a
# key. A wrong URL can return an HTML page; installed as a key file it would
# lock the machine, so each bad line is named and the file is refused.
check_keys_file() {
  local file="$1" line n=0 keys=0 bad=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$(( n + 1 ))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if is_key_line "$line"; then
      keys=$(( keys + 1 ))
    else
      printf 'install: keys: line %d is not a public key\n' "$n" >&2
      bad=1
    fi
  done < "$file"
  if (( bad == 0 && keys == 0 )); then
    printf '%s: keys: no key line (every line is blank or a comment)\n' "install" >&2
  fi
  (( bad == 0 && keys > 0 ))
}

#
# 1. Are we in the installer?
#
if [[ ! -x $install_helios ]]; then
  printf 'install: this is not the Helios installer (%s missing)\n' "$install_helios" >&2
  exit 2
fi

#
# 2. Arguments.
#
[[ -n $keys_url ]] || usage
if (( $# < 2 || $# > 4 )); then
  usage
fi
hostname="$1"
shift
disks=("$@")

if [[ ! $hostname =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  printf 'install: hostname %q must match ^[a-z0-9][a-z0-9-]*$\n' "$hostname" >&2
  usage
fi

# diskinfo -H columns: TYPE DISK VID PID SIZE RMV SSD; the disk name is column 2.
known_disks=$(diskinfo -H | awk -F'\t' '{ print $2 }')
for d in "${disks[@]}"; do
  if ! grep -qx -- "$d" <<< "$known_disks"; then
    printf 'install: disk %s not listed by diskinfo\n' "$d" >&2
    usage
  fi
done

#
# 3. Fetch and verify everything before touching the disk.
#
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

files=(
  firstboot/homicron-firstboot
  firstboot/homicron-firstboot.xml
  firstboot/dhcp-eventhook
)

printf 'fetching from %s\n' "$base_url"
curl -fsSL -o "$tmp/SHA256SUMS" "$base_url/SHA256SUMS" || fail "could not fetch SHA256SUMS"
for f in "${files[@]}"; do
  mkdir -p "$tmp/$(dirname "$f")"
  curl -fsSL -o "$tmp/$f" "$base_url/$f" || fail "could not fetch $f"
  expected=$(awk -v f="$f" '$2 == f { print $1 }' "$tmp/SHA256SUMS")
  actual=$(sum_of "$tmp/$f")
  if [[ -z $expected || $expected != "$actual" ]]; then
    fail "checksum mismatch for $f (the site cache can serve an old file for ten minutes after a deploy; retry then)"
  fi
done

printf 'fetching keys from %s\n' "$keys_url"
curl -fsSL -o "$tmp/authorized_keys" "$keys_url" || fail "could not fetch keys from $keys_url"
check_keys_file "$tmp/authorized_keys" || fail "$keys_url is not a usable authorized_keys file; refusing to install a machine nobody can log in to"

#
# 4. Install.
#
printf 'running install-helios %s %s\n' "$hostname" "${disks[*]}"
"$install_helios" "$hostname" "${disks[@]}"

#
# 5. Seed the installed root.
#
printf 'seeding %s\n' "$altroot"
# Plain cp and chmod: the illumos /usr/sbin/install has different flags from
# GNU install, and the ramdisk PATH finds the illumos one first.
mkdir -p "$altroot/root/.ssh" "$altroot/lib/svc/manifest/site" "$altroot/usr/lib" "$altroot/etc"
chmod 0700 "$altroot/root/.ssh"
cp "$tmp/authorized_keys" "$altroot/root/.ssh/authorized_keys"
chmod 0600 "$altroot/root/.ssh/authorized_keys"

manifest="$altroot/lib/svc/manifest/site/homicron-firstboot.xml"
cp "$tmp/firstboot/homicron-firstboot.xml" "$manifest"
chmod 0644 "$manifest"
cp "$tmp/firstboot/homicron-firstboot" "$altroot/usr/lib/homicron-firstboot"
chmod 0755 "$altroot/usr/lib/homicron-firstboot"

# dhcpagent runs /etc/dhcp/eventhook on every lease event; the hook writes
# /etc/resolv.conf, which nothing else on Helios does.
mkdir -p "$altroot/etc/dhcp"
cp "$tmp/firstboot/dhcp-eventhook" "$altroot/etc/dhcp/eventhook"
chmod 0755 "$altroot/etc/dhcp/eventhook"

# The typed install line gave the ramdisk a working resolv.conf. Seed the
# installed root with it as insurance; the hook overwrites it on the first
# lease.
if grep -q '^nameserver' "$ramdisk_resolv" 2>/dev/null; then
  cp "$ramdisk_resolv" "$altroot/etc/resolv.conf"
  chmod 0644 "$altroot/etc/resolv.conf"
fi

# %q: the first-boot service sources this file, and a URL can hold & or $.
printf 'HOSTNAME=%s\nKEYS_URL=%q\n' "$hostname" "$keys_url" > "$altroot/etc/homicron.conf"
chmod 0644 "$altroot/etc/homicron.conf"

#
# 6. Enable the first-boot service in the installed repository.
#
SVCCFG_REPOSITORY="$altroot/etc/svc/repository.db" svccfg import "$manifest"

printf 'install complete; remove the media and run: reboot\n'
