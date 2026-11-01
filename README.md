# homicron

homicron installs [Helios](https://github.com/oxidecomputer/helios), Oxide's illumos distribution, on a bare-metal x86 machine and prepares it to run [voxel](https://github.com/oxidecomputer/voxel), Oxide's emulated rack lab. It is bash in three stages, served by GitHub Pages at https://homicron.smithjs.org.

## Install a machine

1. Attach the stock Helios installer ISO as virtual media and boot it. Use `helios-install-vga.iso` for a KVM with a display, or `helios-install-ttya.iso` for a serial console. The ISOs are at https://pkg.oxide.computer/install/latest/.
2. At the installer's root prompt, find the NIC with `dladm show-phys` and the disk with `diskinfo`.
3. Run the following command at the prompt to enable DHCP and run this repo's install script.

   ```
   ipadm create-addr -T dhcp rge0/v4 && echo "nameserver $(dhcpinfo -i rge0 DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i https://homicron.smithjs.org/install && bash /tmp/i <hostname> <disk> [<disk> [<disk]]
   ```

   One disk makes a single-disk pool, two make a mirror, three make raidz1. The `resolv.conf` step is required: the installer ramdisk ships an empty `/etc/resolv.conf` and DHCP does not fill it, so without it `curl` cannot resolve the name. Downloading to a file first means a failed download stops the line instead of feeding an empty script to `bash`.
4. When it prints `install complete; remove the media and run: reboot`, do so.
5. On first boot the machine prints its address on the console. It has sshd and mDNS enabled and root accepts the keys in `keys/authorized_keys`. A dhcpagent hook writes `/etc/resolv.conf` from every lease.
6. Create `hosts/<hostname>.env` (see [hosts/README.md](hosts/README.md)) and run:

   ```
   bin/homicron apply <hostname>
   ```

   The runner rsyncs `host/` to the machine and runs each step over ssh. A step that updates the operating system asks for a reboot; the runner reboots, waits, and continues. Run `apply` again after any failure; steps that are already done skip themselves.
7. Build the voxel images on the machine (30 to 45 minutes). The binary is not on the PATH, so the command names its path:

   ```
   bin/homicron ssh <hostname>
   pfexec ~/src/voxel/target/release/voxel image create && pfexec ~/src/voxel/target/release/voxel image create-frr proto
   ```

## Add a mirror disk later

Start with one disk and convert the root pool to a mirror while the machine runs.

```
zpool attach rpool c1t0d0 c2t0d0        # existing disk, then the new one
zpool status rpool                      # wait until "resilvered ... with 0 errors"
bootadm install-bootloader -M -P rpool  # loader onto every disk in the pool
```

Confirm by booting once with the first disk detached. The pool reports DEGRADED until the disk is back.

## What the stages do

| Stage | Where | What |
|---|---|---|
| `install/install.sh` | installer ramdisk | verifies every fetched file against `SHA256SUMS`, runs `install-helios`, seeds `/a` with root's authorized_keys, the first-boot service, the DNS hook, the ramdisk's resolv.conf, and `/etc/homicron.conf` |
| `firstboot/` | first boot, once | DHCP on every physical NIC with a dhcpagent hook for DNS, enable sshd and mDNS, print the address, disable itself |
| `host/NN-*.sh` | over ssh, as root | user and privileges, swap and dump zvols, `pkg update` and build tools, rustup, the falcon dataset, the voxel build, `voxel.toml` |

## Rehearse in a VM

The whole flow runs in qemu/KVM on an x86 Linux host.

On the Linux host, in a clone of this repository:

```
# terminal A: serve the working tree over plain HTTP
test/serve.sh 8000

# terminal B: download the ISO, create a 100 GiB disk, boot the installer
test/qemu.sh install
```

At the installer prompt (the NIC is `vioif0` under qemu):

```
ipadm create-addr -T dhcp vioif0/v4 && echo "nameserver $(dhcpinfo -i vioif0 DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i http://<host-ip>:8000/install && HOMICRON_BASE_URL=http://<host-ip>:8000 bash /tmp/i vm c1t0d0
```

Then `reboot`, quit qemu with `Ctrl-a x` when the loader appears, and boot the installed disk with `test/qemu.sh boot`. ssh is forwarded to port 2222 on the Linux host, so if the Linux host is remote, run apply with the following:

```
HOMICRON_ADDR=<host-ip> bin/homicron apply vm
```

## Development

```
test/lint.sh        shellcheck and bash -n over every script
test/run-tests.sh   bats tests; target commands are faked on PATH
```

CI runs both on every push and deploys the site from `main` with `pages/build-site.sh`.
