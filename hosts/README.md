# Host files

One file per machine, named `hosts/<name>.env`. Each line is `KEY=VALUE`
with no quotes and no shell syntax: the runner reads the value literally.
A line that breaks the rule stops the runner with exit 2 and the line number.
A variable that is already set in the environment wins over the file, so
private addresses never need to be committed. Values set in the environment
follow the same rule.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `HOMICRON_USER` | yes | | Login to create on the host. |
| `HOMICRON_UID` | yes | | Numeric uid for that login. Match the laptop uid. |
| `HOMICRON_ADDR` | no | `<name>.local` | ssh target. Pass private names in the environment. |
| `HOMICRON_PORT` | no | `22` | ssh port. The qemu test VM forwards a high port. |
| `SWAP_SIZE` | no | `16G` | Size of the `rpool/swap` zvol. Used only when the zvol is created; changing it later does nothing. |
| `DUMP_SIZE` | no | `16G` | Size of the `rpool/dump` zvol. Used only when the zvol is created; changing it later does nothing. |
| `FALCON_DATASET` | no | empty | ZFS dataset for voxel images and disks. Empty uses the rpool default. |
| `VOXEL_REF` | no | `main` | Git ref of oxidecomputer/voxel to build. |
| `VOXEL_SLEDS` | no | `4` | `topology.sleds` in voxel.toml. |
| `VOXEL_SLED_MEMORY_GB` | no | `8` | `topology.sled_memory_gb` in voxel.toml. |

`vm.env` is the qemu test VM. Run it with the Linux host's address in the
environment:

```
HOMICRON_ADDR=<linux-host> bin/homicron apply vm
```
