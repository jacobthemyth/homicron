load helpers/fakes

SCRIPT="$BATS_TEST_DIRNAME/../test/qemu.sh"

@test "dry run prints a kvm command with ssh forwarding and the iso for install" {
  HOMICRON_VM_DIR=/tmp/x HOMICRON_SSH_PORT=2345 run "$SCRIPT" --dry-run install
  [ "$status" -eq 0 ]
  [[ "$output" == *"-enable-kvm"* ]]
  [[ "$output" == *"hostfwd=tcp::2345-:22"* ]]
  [[ "$output" == *"-cdrom /tmp/x/helios-install-ttya.iso"* ]]
  [[ "$output" == *"-boot d"* ]]
}

@test "boot mode omits the cdrom" {
  HOMICRON_VM_DIR=/tmp/x run "$SCRIPT" --dry-run boot
  [ "$status" -eq 0 ]
  [[ "$output" != *"-cdrom"* ]]
  [[ "$output" == *"file=/tmp/x/disk.qcow2"* ]]
}

@test "unknown mode is a usage error" {
  run "$SCRIPT" --dry-run fly
  [ "$status" -eq 2 ]
}

@test "HOMICRON_VM_DISK2 adds a second virtio disk" {
  HOMICRON_VM_DIR=/tmp/x HOMICRON_VM_DISK2=20G run "$SCRIPT" --dry-run boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"file=/tmp/x/disk2.qcow2,if=virtio,format=qcow2"* ]]
  HOMICRON_VM_DIR=/tmp/x run "$SCRIPT" --dry-run boot
  [[ "$output" != *"disk2"* ]]
}

@test "HOMICRON_VM_NIC2=yes adds a second virtio nic with no peer" {
  HOMICRON_VM_DIR=/tmp/x HOMICRON_VM_NIC2=yes run "$SCRIPT" --dry-run boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"-netdev socket,id=n1,listen=:0"* ]]
  [[ "$output" == *"-device virtio-net-pci,netdev=n1"* ]]
  HOMICRON_VM_DIR=/tmp/x run "$SCRIPT" --dry-run boot
  [[ "$output" != *"netdev=n1"* ]]
}

@test "a failed iso download leaves no iso behind" {
  fakes_setup
  make_fake curl 18
  dir="$BATS_TEST_TMPDIR/vm"
  HOMICRON_VM_DIR="$dir" run "$SCRIPT" install
  [ "$status" -eq 18 ]
  [ ! -e "$dir/helios-install-ttya.iso" ]
  assert_called "^curl -fL -o $dir/helios-install-ttya.iso.part "
}
