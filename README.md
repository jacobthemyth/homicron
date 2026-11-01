# homicron

homicron installs [Helios](https://github.com/oxidecomputer/helios), Oxide's
illumos distribution, on a bare-metal x86 machine and prepares it to run
[voxel](https://github.com/oxidecomputer/voxel), Oxide's emulated rack lab.
It is bash in three stages, served by GitHub Pages at
<https://homicron.smithjs.org>.

Design: [docs/superpowers/specs/2026-10-31-homicron-design.md](docs/superpowers/specs/2026-10-31-homicron-design.md).

## Install a machine

1. Attach the stock Helios installer ISO as virtual media and boot it. Use
   `helios-install-vga.iso` for a KVM with a display, or `helios-install-ttya.iso`
   for a serial console. The ISOs are at <https://pkg.oxide.computer/install/latest/>.
2. At the installer's root prompt, find the NIC with `dladm show-phys` and the
   disk with `diskinfo`.
3. Type one line:

   ```
   ipadm create-addr -T dhcp rge0/v4 && echo "nameserver $(dhcpinfo -i rge0 DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i https://homicron.smithjs.org/install && bash /tmp/i <hostname> <disk>
   ```

   One disk makes a single-disk pool, two make a mirror, three make raidz1.
   The `resolv.conf` step is required: the installer ramdisk ships an empty
   `/etc/resolv.conf` and DHCP does not fill it, so without it `curl` cannot
   resolve the name. Downloading to a file first means a failed download
   stops the line instead of feeding an empty script to `bash`.
4. When it prints `install complete; remove the media and run: reboot`,
   remove the media and run `reboot`.
5. On first boot the machine prints its address on the console. It has sshd
   and mDNS enabled and root accepts the keys in `keys/authorized_keys`.
6. Create `hosts/<hostname>.env` (see [hosts/README.md](hosts/README.md)) and run:

   ```
   bin/homicron apply <hostname>
   ```

   The runner rsyncs `host/` to the machine and runs each step over ssh. A
   step that updates the operating system asks for a reboot; the runner
   reboots, waits, and continues. Run `apply` again after any failure; steps
   that are already done skip themselves.
7. Build the voxel images on the machine (30 to 45 minutes):

   ```
   bin/homicron ssh <hostname>
   pfexec voxel image create && pfexec voxel image create-frr proto
   ```

## What the stages do

| Stage | Where | What |
|---|---|---|
| `install/install.sh` | installer ramdisk | verifies every fetched file against `SHA256SUMS`, runs `install-helios`, seeds `/a` with root's authorized_keys, the first-boot service, and `/etc/homicron.conf` |
| `firstboot/` | first boot, once | DHCP on every physical NIC, enable sshd and mDNS, print the address, disable itself |
| `host/NN-*.sh` | over ssh, as root | user and privileges, swap and dump zvols, `pkg update` and build tools, rustup, the falcon dataset, the voxel build, `voxel.toml` |

Every host step checks its own end state first and does nothing when it
already holds. The second `apply` on a finished machine changes nothing.

## Rehearse in a VM

The whole flow runs in qemu/KVM on an x86 Linux host. An Apple Silicon Mac
cannot run x86 Helios at a useful speed.

On the Linux host, in a clone of this repository:

```
# terminal A: serve the working tree over plain HTTP
test/serve.sh 8000

# terminal B: download the ISO, create a 100 GiB disk, boot the installer
test/qemu.sh install
```

At the installer prompt (the NIC is `vioif0` under qemu):

```
ipadm create-addr -T dhcp vioif0/v4 && echo "nameserver $(dhcpinfo -i vioif0 DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i http://10.0.2.2:8000/install && HOMICRON_BASE_URL=http://10.0.2.2:8000 bash /tmp/i vm c1t0d0
```

Then `reboot`, quit qemu with `Ctrl-a x` when the loader appears, and boot
the installed disk with `test/qemu.sh boot`. ssh is forwarded to port 2222
on the Linux host, so from the laptop:

```
HOMICRON_ADDR=<linux-host> bin/homicron apply vm
```

## Confirmed on first install

Facts the design assumed, and what the first real runs showed. "VM" is the
qemu/KVM rehearsal on 2026-10-31 with `helios-3.0.23976`; the IMB-A1002
column is filled in after the first physical install.

| Item | VM | IMB-A1002 |
|---|---|---|
| `ipadm create-addr -T dhcp` works in the installer ramdisk | yes | |
| the ramdisk's `curl` trusts the GitHub Pages certificate | yes (`ssl_verify_result` 0, HTTP 200) | |
| `SVCCFG_REPOSITORY=/a/etc/svc/repository.db svccfg import` enables the first-boot service | yes, `general/enabled true` before reboot | |
| the IMB-A1002 NIC appears as `rge0` | n/a (`vioif0`) | |
| `network/ssh` is disabled on a fresh install, so first boot must enable it | no: it was already online; the enable is a no-op | |

Findings from the rehearsal that changed the code:

- `dhcpagent` records the DNS servers from the lease but never writes
  `/etc/resolv.conf` (that is nwam's job). First boot now writes it from
  `dhcpinfo` when the file is absent, and the typed install line writes it
  in the ramdisk, where the file exists but is empty.
- The SMF method PATH is `/usr/sbin:/usr/bin`; `dhcpinfo` lives in `/sbin`.
- `profiles <user>` indents each profile name, so an exact-line match fails.
- A fresh install's `pkg update` exits 1 with "pkg(7) appears to be out of
  date" until `pkg install pkg:/package/pkg` runs.

## Development

```
test/lint.sh        shellcheck and bash -n over every script
test/run-tests.sh   bats tests; target commands are faked on PATH
```

CI runs both on every push and deploys the site from `main` with
`pages/build-site.sh`. The custom domain was set with:

```
gh api -X PUT repos/jacobthemyth/homicron/pages -f cname=homicron.smithjs.org
gh api -X PUT repos/jacobthemyth/homicron/pages -F https_enforced=true
```

Nothing private belongs in this repository. Host addresses are passed in the
environment; see [hosts/README.md](hosts/README.md).
