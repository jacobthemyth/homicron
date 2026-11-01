#!/bin/bash
#
# Boot the stock Helios installer, or the installed disk, under qemu/KVM on
# an x86 Linux host. The serial console is on stdio; quit with Ctrl-a x.
#
#   test/qemu.sh [--dry-run] install    download the ISO, create the disk, boot the installer
#   test/qemu.sh [--dry-run] boot       boot the installed disk
#
# Environment (defaults in parentheses):
#   HOMICRON_VM_DIR    (test/vm)      ISO, disk image, and firmware vars
#   HOMICRON_ISO_URL   (https://pkg.oxide.computer/install/latest/helios-install-ttya.iso)
#   HOMICRON_VM_MEM    (16G)
#   HOMICRON_VM_CPUS   (8)
#   HOMICRON_VM_DISK   (100G)
#   HOMICRON_VM_DISK2  (unset)        size of an optional second disk, for mirror rehearsals
#   HOMICRON_VM_NIC2   (unset)        yes adds a second NIC with no peer, like an uncabled port
#   HOMICRON_SSH_PORT  (2222)         host port forwarded to guest port 22
#   OVMF_CODE          (/usr/share/edk2/x64/OVMF_CODE.4m.fd)
#   OVMF_VARS          (/usr/share/edk2/x64/OVMF_VARS.4m.fd)
#
# The guest sits on qemu user-mode networking: it gets 10.0.2.15 by DHCP and
# reaches the host at 10.0.2.2.
#
set -o errexit -o pipefail -o nounset

root=$(cd "$(dirname "$0")/.." && pwd)
vm_dir=${HOMICRON_VM_DIR:-"$root/test/vm"}
iso_url=${HOMICRON_ISO_URL:-https://pkg.oxide.computer/install/latest/helios-install-ttya.iso}
mem=${HOMICRON_VM_MEM:-16G}
cpus=${HOMICRON_VM_CPUS:-8}
disk_size=${HOMICRON_VM_DISK:-100G}
disk2_size=${HOMICRON_VM_DISK2:-}
nic2=${HOMICRON_VM_NIC2:-}
ssh_port=${HOMICRON_SSH_PORT:-2222}
ovmf_code=${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}
ovmf_vars=${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}

iso="$vm_dir/$(basename "$iso_url")"
disk="$vm_dir/disk.qcow2"
disk2="$vm_dir/disk2.qcow2"
vars="$vm_dir/vars.fd"

usage() {
  printf 'usage: test/qemu.sh [--dry-run] install|boot\n' >&2
  exit 2
}

dry_run=no
if [[ ${1:-} == --dry-run ]]; then
  dry_run=yes
  shift
fi
mode=${1:-}
case $mode in
  install|boot) ;;
  *) usage ;;
esac

cmd=(
  qemu-system-x86_64
  -enable-kvm -cpu host -smp "$cpus" -m "$mem" -machine q35
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
  -drive "if=pflash,format=raw,file=$vars"
  -drive "file=$disk,if=virtio,format=qcow2"
)
if [[ -n $disk2_size ]]; then
  cmd+=(-drive "file=$disk2,if=virtio,format=qcow2")
fi
cmd+=(
  -netdev "user,id=n0,hostfwd=tcp::$ssh_port-:22"
  -device "virtio-net-pci,netdev=n0"
)
if [[ $nic2 == yes ]]; then
  # A socket netdev with no peer never answers DHCP: an uncabled port.
  cmd+=(-netdev "socket,id=n1,listen=:0" -device "virtio-net-pci,netdev=n1")
fi
cmd+=(-nographic -serial mon:stdio)
if [[ $mode == install ]]; then
  cmd+=(-cdrom "$iso" -boot d)
fi

if [[ $dry_run == yes ]]; then
  printf '%s\n' "${cmd[*]}"
  exit 0
fi

mkdir -p "$vm_dir"
if [[ $mode == install && ! -f $iso ]]; then
  printf 'downloading %s\n' "$iso_url"
  # Download beside the target and rename on success, so an interrupted
  # transfer never leaves a truncated file that the check above accepts.
  curl -fL -o "$iso.part" "$iso_url"
  mv "$iso.part" "$iso"
fi
if [[ ! -f $disk ]]; then
  qemu-img create -f qcow2 "$disk" "$disk_size"
fi
if [[ -n $disk2_size && ! -f $disk2 ]]; then
  qemu-img create -f qcow2 "$disk2" "$disk2_size"
fi
if [[ ! -f $vars ]]; then
  cp "$ovmf_vars" "$vars"
fi

exec "${cmd[@]}"
