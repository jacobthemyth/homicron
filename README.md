# homicron

homicron installs [Helios](https://github.com/oxidecomputer/helios), Oxide's illumos distribution, on a bare-metal x86 machine and prepares it to run [voxel](https://github.com/oxidecomputer/voxel), Oxide's emulated rack lab. It is bash in three stages, served by GitHub Pages at https://homicron.smithjs.org.

## Install a machine

1. Attach the stock Helios installer ISO as virtual media and boot it. Use `helios-install-vga.iso` for a KVM with a display, or `helios-install-ttya.iso` for a serial console. The ISOs are at https://pkg.oxide.computer/install/latest/.
2. At the installer's root prompt, find the NIC with `dladm show-phys` and the disk with `diskinfo`.
3. Run the following command at the prompt to enable DHCP and run this repo's install script.

   ```
   ipadm create-addr -T dhcp <nic>/v4 && echo "nameserver $(dhcpinfo -i <nic> DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i https://homicron.smithjs.org/install && HOMICRON_KEYS_URL=https://github.com/<user>.keys bash /tmp/i <hostname> <disk> [<disk> [<disk>]]
   ```

   One disk makes a single-disk pool, two make a mirror, three make raidz1. `HOMICRON_KEYS_URL` names the public keys root will accept, and GitHub serves an account's keys at `https://github.com/<user>.keys`. The `resolv.conf` step is required: the installer ramdisk ships an empty `/etc/resolv.conf` and DHCP does not fill it, so without it `curl` cannot resolve the name. Downloading to a file first means a failed download stops the line instead of feeding an empty script to `bash`.
4. When it prints `install complete; remove the media and run: reboot`, do so.
5. On first boot the machine brings up DHCP and IPv6 autoconfiguration on every cabled NIC and prints its addresses on the console. It has sshd and mDNS enabled and root accepts the keys the install line named. A dhcpagent hook writes `/etc/resolv.conf` from every lease. A NIC cabled later needs `ipadm create-addr -T dhcp <nic>/v4` by hand.
6. Create `hosts/<hostname>.env` (see [hosts/README.md](hosts/README.md)) and run:

   ```
   bin/homicron apply <hostname>
   ```

   `apply` ships the public keys of this workstation (`~/.ssh/*.pub`) to root and to the new login. A hosts file that sets `HOMICRON_KEYS` replaces that default, and the login and uid default to this workstation's. The runner rsyncs `host/` to the machine and starts the SMF service `site/homicron-apply`, which runs each step in order on the machine itself and ends with the voxel image build (30 to 45 minutes); the output streams to your terminal. The service, not the runner, owns the run: Ctrl-C or a dropped connection leaves it going on the machine, and the same `apply` command rejoins it. A step that updates the operating system reboots the machine; the runner waits and reconnects. A failed step leaves the service in `maintenance` with the step's output in the stream; fix the cause and run `apply` again, which clears the service and reruns the steps, each skipping itself when already done.

   When `apply complete` prints, the rack launches under the SMF service `site/voxel-rack`, which takes about ten minutes. The service destroys and relaunches the rack after every boot, so the rack comes back empty: voxel has no way to resume a rack, and a plain `voxel launch` on the surviving disks fails in rack setup. The console is `https://recovery.sys.rack1.oxide.test`, over HTTPS with a self-signed certificate that voxel supplies, with login `recovery` and password `oxide`. Your workstation needs a route through the machine and a hosts entry for one of the Nexus addresses that the rack's DNS returns:

   ```
   sudo route add -net 198.51.100.0/24 <machine-address>
   dig +short @198.51.100.20 recovery.sys.rack1.oxide.test A
   printf '<one-nexus-address> recovery.sys.rack1.oxide.test\n' | sudo tee -a /etc/hosts
   ```

   If the launch fails, `svcs -xv site/voxel-rack` names the state and `/var/log/voxel-rack.log` holds voxel's output. `svcadm clear site/voxel-rack` retries. `svcadm disable site/voxel-rack` destroys the rack and `svcadm restart site/voxel-rack` rebuilds it. A `pfexec voxel destroy` by hand leaves the service online with no rack, so use `svcadm` for the rack's lifecycle. The service waits for `site/homicron-apply` to be online, so a rack never launches while an apply runs. If someone disables `site/homicron-apply` by hand, the rack service waits forever, and `svcadm enable site/homicron-apply` is the fix. To recreate rack content after each launch, put an executable `~/.config/voxel/post-launch.sh` on the machine. It runs as your login after every successful launch against an empty rack, with a bound of ten minutes, and its exit status is logged but never fails the service. The rack is new every time, so an API token minted earlier is gone with it. The hook has to log in each run. The recovery silo takes a password login that returns a session cookie, so the example below uses that cookie for one API call:

   ```
   #!/bin/bash
   set -o errexit
   host=https://recovery.sys.rack1.oxide.test
   nexus=$(dig +short @198.51.100.20 recovery.sys.rack1.oxide.test A | head -1)
   jar=$(mktemp)
   curl -k -sS --resolve "recovery.sys.rack1.oxide.test:443:$nexus" -c "$jar" -H 'Content-Type: application/json' \
     -d '{"username":"recovery","password":"oxide"}' "$host/v1/login/recovery/local"
   curl -k -sS --resolve "recovery.sys.rack1.oxide.test:443:$nexus" -b "$jar" -H 'Content-Type: application/json' \
     -d '{"name":"lab","description":"created by post-launch.sh"}' "$host/v1/projects"
   rm -f "$jar"
   ```

## Known issue: Linux guests freeze under voxel

Current Helios advertises a viona feature that the propolis behind voxel's pinned falcon mishandles ([falcon issue 383](https://github.com/oxidecomputer/falcon/issues/383)). A Linux guest with a NIC freezes when it brings the NIC up, and `voxel image create-frr` stops at the Debian builder's login with `timeout waiting for data`. Step 65 adds `set viona:viona_feat_disable_mask=0x20000000` to `/etc/system`, which the kernel reads at the next boot, and sets the same value in the running kernel now, loading the viona module first when no VM has loaded it yet. The step logs a warning when the voxel checkout is not at the commit the workaround was validated on. Once voxel pins a falcon whose propolis is at or past commit `6588611`, remove the line and the step.

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
| `install/install.sh` | installer ramdisk | verifies every fetched file against `SHA256SUMS`, runs `install-helios`, seeds `/a` with the keys from `HOMICRON_KEYS_URL`, the first-boot service, the DNS hook, the ramdisk's resolv.conf, and `/etc/homicron.conf` |
| `firstboot/` | first boot, once | DHCP and IPv6 autoconfiguration on every cabled NIC with a dhcpagent hook for DNS, enable sshd and mDNS, print the addresses, disable itself |
| `host/NN-*.sh` | on the machine, as the SMF service `site/homicron-apply` | user and privileges, swap and dump zvols, the network layout and chrony, `pkg update` and build tools, rustup, the falcon dataset, the voxel build, the viona workaround, the voxel images, the `voxel.toml` keys, the propolis binary, the rack service |

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
ipadm create-addr -T dhcp vioif0/v4 && echo "nameserver $(dhcpinfo -i vioif0 DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i http://<host-ip>:8000/install && HOMICRON_KEYS_URL=https://github.com/<user>.keys HOMICRON_BASE_URL=http://<host-ip>:8000 bash /tmp/i vm c1t0d0
```

The VM reaches GitHub through qemu's user-mode network, so the keys URL works unchanged.

For a clean reinstall, delete `test/vm/disk.qcow2` and `test/vm/vars.fd` together. The firmware keeps its boot order in `vars.fd`, and a stale copy tries four network boot entries, about three minutes, before it reaches the disk or the ISO. A reinstall also changes the VM's ssh host key, so remove the old one with `ssh-keygen -R '[<host-ip>]:2222'` before the first `apply`.

Then `reboot`, quit qemu with `Ctrl-a x` when the loader appears, and boot the installed disk with `test/qemu.sh boot`. ssh is forwarded to port 2222 on the Linux host, so if the Linux host is remote, run apply with the following:

```
HOMICRON_ADDR=<host-ip> bin/homicron apply vm
```

## Run your own copy

The published site at https://homicron.smithjs.org works for anyone, because the install line names the keys. A fork is only needed to change the code.

1. Fork the repository.
2. Enable Pages with the workflow build type:

   ```
   gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow
   ```

3. If you want a custom domain, point a DNS CNAME record at `<owner>.github.io` and run:

   ```
   gh api -X PUT repos/<owner>/<repo>/pages -f cname=<domain>
   ```

   GitHub then issues a certificate for the domain, which takes a few minutes. Once `gh api repos/<owner>/<repo>/pages --jq .https_certificate.state` prints `approved`, turn on HTTPS:

   ```
   gh api -X PUT repos/<owner>/<repo>/pages -F https_enforced=true
   ```

   GitHub reads the domain from this setting. The deploy workflow learns the site address from GitHub, so no file in the repository names it.

4. Push to `main` and type the install line with your site address in place of `https://homicron.smithjs.org`.

## Development

```
test/lint.sh        shellcheck and bash -n over every script
test/run-tests.sh   bats tests; target commands are faked on PATH
```

CI runs both on every push and deploys the site from `main` with `pages/build-site.sh`.

On the machine, `host/apply.sh` is the start method of `site/homicron-apply` and runs the steps; `host/start-apply.sh` imports `host/homicron-apply.xml` and starts a run; `host/watch-apply.sh` streams the log to the runner. The log is `/var/homicron/apply.log`, on its own dataset `rpool/homicron` so it survives the boot environment switch of an OS update, with one file per step under `/var/log/homicron`. `HOMICRON_APPLY_TIMEOUT` (default 7200 seconds) bounds how long one `apply` watches before telling you to rejoin. Use `svcadm` and `svcs` on the service rather than running `apply.sh` by hand.

The rack itself runs under `site/voxel-rack`: `host/voxel-rack.xml` is its manifest, installed by step 90, and `host/voxel-rack-start.sh` and `host/voxel-rack-stop.sh` are its methods, which destroy and launch the rack as your login through `pfexec`. The service depends on `site/homicron-apply` being online, so the rack waits for an apply to finish. Its log is `/var/log/voxel-rack.log`.
