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
