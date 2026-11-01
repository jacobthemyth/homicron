#!/bin/bash
#
# homicron stage 1. Runs in the Helios installer ramdisk, as root.
#
#   ipadm create-addr -T dhcp rge0/v4 && \
#     echo "nameserver $(dhcpinfo -i rge0 DNSserv)" > /etc/resolv.conf && \
#     curl -fsSLo /tmp/i https://homicron.smithjs.org/install && bash /tmp/i <hostname> <disk>...
#
# Runs install-helios, then seeds the new root (still mounted at /a) with the
# SSH keys, the first-boot service, and /etc/homicron.conf. Does not reboot.
#
set -o errexit -o pipefail -o nounset

base_url=${HOMICRON_BASE_URL:-https://homicron.smithjs.org}
altroot=${HOMICRON_ALTROOT:-/a}
install_helios=${HOMICRON_INSTALL_HELIOS:-/usr/bin/install-helios}

usage() {
  printf 'usage: install <hostname> <disk> [<disk> [<disk>]]\n' >&2
  printf '  one disk: single; two: mirror; three: raidz1\n' >&2
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

known_disks=$(diskinfo -H | awk '{ print $1; print $2 }')
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
  keys/authorized_keys
)

printf 'fetching from %s\n' "$base_url"
curl -fsSL -o "$tmp/SHA256SUMS" "$base_url/SHA256SUMS" || fail "could not fetch SHA256SUMS"
for f in "${files[@]}"; do
  mkdir -p "$tmp/$(dirname "$f")"
  curl -fsSL -o "$tmp/$f" "$base_url/$f" || fail "could not fetch $f"
  expected=$(awk -v f="$f" '$2 == f { print $1 }' "$tmp/SHA256SUMS")
  actual=$(sum_of "$tmp/$f")
  if [[ -z $expected || $expected != "$actual" ]]; then
    fail "checksum mismatch for $f"
  fi
done

if ! grep -Eq '^(ssh|ecdsa)-' "$tmp/keys/authorized_keys"; then
  fail "authorized_keys contains no key; refusing to install a machine nobody can log in to"
fi

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
cp "$tmp/keys/authorized_keys" "$altroot/root/.ssh/authorized_keys"
chmod 0600 "$altroot/root/.ssh/authorized_keys"

manifest="$altroot/lib/svc/manifest/site/homicron-firstboot.xml"
cp "$tmp/firstboot/homicron-firstboot.xml" "$manifest"
chmod 0644 "$manifest"
cp "$tmp/firstboot/homicron-firstboot" "$altroot/usr/lib/homicron-firstboot"
chmod 0755 "$altroot/usr/lib/homicron-firstboot"

printf 'HOSTNAME=%s\nBASE_URL=%s\n' "$hostname" "$base_url" > "$altroot/etc/homicron.conf"
chmod 0644 "$altroot/etc/homicron.conf"

#
# 6. Enable the first-boot service in the installed repository.
#
SVCCFG_REPOSITORY="$altroot/etc/svc/repository.db" svccfg import "$manifest"

printf 'install complete; remove the media and run: reboot\n'
