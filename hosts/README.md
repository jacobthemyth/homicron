# Host files

One file per machine, named `hosts/<name>.env`. Each line is `KEY=VALUE`
with no quotes and no shell syntax: the runner reads the value literally.
The key is uppercase letters, digits, and underscores. The value holds only
letters, digits, and `. _ / : @ % + , -`. Only the variables in the table
below are allowed. A line that breaks a rule stops the runner with exit 2
and the line number.
A variable that is already set in the environment wins over the file, so
private addresses never need to be committed. Values set in the environment
follow the same rule.
Git ignores `hosts/*.env`, so a hosts file is private by default. `vm.env`
is the one tracked exception.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `HOMICRON_USER` | no | the workstation login (`id -un`) | Login to create on the host. |
| `HOMICRON_UID` | no | the workstation uid (`id -u`) | Numeric uid for that login. Files that move between the two machines keep their numeric owner, so a matching uid keeps that owner readable on both sides. |
| `HOMICRON_KEYS` | no | every `~/.ssh/*.pub` on the workstation | Public keys for root and the login, as a URL or a file path. A relative path resolves from the directory `apply` runs in. Runner-only, never shipped to the host. |
| `HOMICRON_ADDR` | no | `<name>.local` | ssh target. Pass private names in the environment. |
| `HOMICRON_PORT` | no | `22` | ssh port. The qemu test VM forwards a high port. |
| `SWAP_SIZE` | no | `16G` | Size of the `rpool/swap` zvol. Used only when the zvol is created; changing it later does nothing. |
| `DUMP_SIZE` | no | `16G` | Size of the `rpool/dump` zvol. Used only when the zvol is created; changing it later does nothing. |
| `FALCON_DATASET` | no | empty | ZFS dataset for voxel images and disks. Empty uses the rpool default. |
| `VOXEL_REF` | no | `main` | Git ref of oxidecomputer/voxel to build. |
| `VOXEL_SLEDS` | no | `4` | `topology.sleds` in voxel.toml. |
| `VOXEL_SLED_MEMORY_GB` | no | `8` | `topology.sled_memory_gb` in voxel.toml. |

A URL that holds `?`, `=`, or `&` breaks the value rule above, so pass it
in the environment: `HOMICRON_KEYS=<url> bin/homicron apply <name>`.

`apply` overwrites root's and the login's `authorized_keys` with the shipped
file. Two workstations that both use the default remove each other's key on
every run. A setup with more than one workstation points `HOMICRON_KEYS` at
one shared URL, the same URL the install line used.

The default address `<name>.local` needs an mDNS resolver on the
workstation. macOS has one. Many Linux hosts get one from avahi or
systemd-resolved.

`vm.env` is the qemu test VM. It takes the workstation login and uid. Run
it with the Linux host's address in the environment:

```
HOMICRON_ADDR=<linux-host> bin/homicron apply vm
```
