# homicron design

Date: 2026-10-31

homicron turns a bare-metal x86 machine into a Helios host that runs
[voxel](https://github.com/oxidecomputer/voxel), Oxide's emulated rack lab.
It is a git repository of bash scripts, served by GitHub Pages, that a person
applies to one machine at a time. Helios is Oxide's illumos distribution.

## Goals

- Install Helios on a machine with only a remote console (JetKVM or IPMI) and
  a way to attach the stock Helios ISO as virtual media.
- Type one line at the installer console. After that line, the machine never
  needs the console again.
- Run the rest of the setup from a laptop over SSH. Every step is idempotent
  (safe to run twice) so a failed run can be repeated.
- Reuse the same repository, unchanged, for the next machine. Per-machine
  differences live in one small file per machine.

## Non-goals

- A custom Helios ISO. The image-builder tool only runs on illumos, so a
  custom ISO would need a Helios machine before the first Helios machine
  exists, and every Helios update would need a rebuild.
- Scripting the ISO mount or the installer keystrokes through the JetKVM or
  IPMI. The install is three short commands and both consoles already attach
  media.
- Ansible or any other configuration tool that needs an agent or an
  interpreter on the target.
- Running `voxel image create`. Image builds take 30 to 45 minutes and leave
  no host state that other steps depend on. The README gives the commands.
- Secrets or private details. Everything in the repository is public:
  scripts, public SSH keys, and non-secret host variables. Private host
  names and addresses are passed in the environment, never committed.

## Facts the design depends on

These were read from the helios-engvm repository and the voxel operator guide
on 2026-10-31.

- The stock installer ISO boots to a root shell. The person runs `diskinfo`
  to find the disk and `install-helios <hostname> <disk>...` to install. One
  disk makes a single-disk pool, two make a mirror, three make raidz1.
- `install-helios` leaves the new root mounted at `/a` when it finishes. It
  creates `/a/root/.ssh`, sets sshd to `PermitRootLogin without-password`,
  and gives root a blank password. It does not configure any network
  interface. It prints `should be ok to reboot now` and returns.
- The installer ramdisk contains `curl`. The installer's own network-boot
  mode uses it.
- voxel needs bare metal, 64 GB of RAM for the default four-sled topology,
  500 GiB or more of flash, one physical NIC with IPv4, a Rust toolchain, and
  `pfexec` (illumos privilege escalation) for launch and image builds.
- The first machine is an ASRock Industrial IMB-A1002 (AM5, B650) with an
  AMD EPYC 4545. Its two Realtek RTL8111H ports use the illumos `rge`
  driver. Later machines have IPMI instead of a JetKVM.

## Architecture

Changes after the review of 2026-11-01 are in
[2026-11-01-review-fixes-design.md](2026-11-01-review-fixes-design.md).

Three stages, split by where and as whom they run.

| Stage | Runs where | Runs as | Trigger |
|---|---|---|---|
| 1 install | installer ramdisk | root | one typed line |
| 2 first boot | installed system, once | root, under SMF | reboot after stage 1 |
| 3 apply | installed system, over SSH | root via the seeded key | `bin/homicron apply <name>` on the laptop |

SMF is the illumos service manager.

### Repository layout

```
homicron/
  install/install.sh          stage 1
  firstboot/
    homicron-firstboot.xml    SMF manifest
    homicron-firstboot        method script
  host/
    run-step.sh               runs one step on the box with logging
    10-user.sh
    20-swap-dump.sh
    30-pkg.sh
    40-rust.sh
    50-falcon.sh
    60-voxel.sh
    70-voxel-conf.sh
  hosts/<name>.env            per-machine variables (hosts/vm.env for the test VM)
  keys/authorized_keys        public keys seeded for root, copied to the user
  bin/homicron                laptop-side runner
  test/qemu.sh                boots the stock ISO under qemu/KVM on an x86 Linux host
  test/serve.sh               serves a locally built _site/ over plain HTTP for stage 1 tests
  pages/
    index.html                one page for humans: the typed line and what it does
    CNAME                     homicron.smithjs.org
    .nojekyll
  .github/workflows/pages.yml build and deploy the site, run shellcheck
  docs/superpowers/specs/     this document
  README.md
```

## Delivery: GitHub Pages

The site is `https://homicron.smithjs.org`. A GitHub Actions workflow runs on
every push to `main`. It fails if `shellcheck` or `bash -n` fails on any
script. Then it assembles `_site/` and deploys it with
`actions/upload-pages-artifact` and `actions/deploy-pages`. The scripts have
one source of truth in the stage directories. Nothing is copied by hand.

```
_site/
  install              <- install/install.sh
  firstboot/           <- firstboot/*
  keys/authorized_keys <- keys/authorized_keys
  SHA256SUMS           generated: sha256 of every file above
  index.html, CNAME, .nojekyll
```

Constraints:

- The repository must be public, because GitHub Pages on a free account only
  serves public repositories. The repository holds nothing secret.
- The DNS CNAME record for `homicron.smithjs.org` must point at
  `jacobthemyth.github.io` before the custom domain is set in the repository
  settings. GitHub redirects the `github.io` URL to the custom domain as soon
  as it is set.
- `pages/CNAME` is in the first commit so a Pages deploy never clears the
  custom domain.

## Stage 1: install

The person attaches the stock `helios-install-vga.iso` (or `ttya` for a
serial console) as virtual media, boots it, and types:

```
ipadm create-addr -T dhcp rge0/v4 && echo "nameserver $(dhcpinfo -i rge0 DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i https://homicron.smithjs.org/install && bash /tmp/i <hostname> <disk>...
```

The NIC name comes from `dladm show-phys` on the installer console. The disk
name comes from `diskinfo`.

`install.sh` reads the base URL from the environment variable
`HOMICRON_BASE_URL` and defaults to `https://homicron.smithjs.org`. The
override exists so a development copy of the site can be tested before it is
pushed, with `curl ... | HOMICRON_BASE_URL=http://10.0.2.2:8000 bash -s -- ...`.
The value written to `/etc/homicron.conf` is the one that was used.

`install.sh` does this, in order, and stops at the first failure:

1. Make sure that `/usr/bin/install-helios` exists. If it does not, print
   `this is not the Helios installer` and exit 2.
2. Make sure that there are at least two arguments and at most four. Make
   sure that every disk argument appears in `diskinfo -H`. Otherwise print
   the usage line and exit 2.
3. Download `SHA256SUMS`, `firstboot/homicron-firstboot.xml`,
   `firstboot/homicron-firstboot`, and `keys/authorized_keys` into a
   temporary directory. Make sure that each file matches its sum. If any
   download or sum fails, exit 1 before touching the disk.
4. Run `install-helios <hostname> <disk>...`. If it fails, exit with its
   status.
5. Write into `/a`:
   - `root/.ssh/authorized_keys`, mode 0600.
   - `lib/svc/manifest/site/homicron-firstboot.xml`, mode 0644.
   - `usr/lib/homicron-firstboot`, mode 0755.
   - `etc/homicron.conf` with two lines: `HOSTNAME=<hostname>` and
     `BASE_URL=https://homicron.smithjs.org`.
6. Import the manifest into the installed system's SMF repository so the
   service is enabled on first boot. The method is
   `SVCCFG_REPOSITORY=/a/etc/svc/repository.db svccfg import <manifest>`,
   or the `svccfg -s` form if that works better in the ramdisk. The plan
   must confirm one of the two on a real install.
7. Print `install complete; remove the media and run: reboot`. Do not
   reboot. The person reads the output first.

The script never writes to the disk before step 4, and never leaves `/a` in
a half-seeded state without printing which step failed.

## Stage 2: first boot

The SMF service `site/homicron-firstboot:default` depends on
`svc:/milestone/network:default` and `svc:/system/filesystem/local:default`.
It is a transient service: its method runs once per boot and must exit 0.

The method script `/usr/lib/homicron-firstboot`:

1. Reads `/etc/homicron.conf`.
2. For each link in `dladm show-phys -p -o link`: if `ipadm show-addr` shows
   no address object on that link, run `ipadm create-addr -T dhcp <link>/v4`.
   An existing address is left alone.
3. Runs `svcadm enable network/ssh` and `svcadm enable network/dns/multicast`.
4. Waits up to 60 seconds for any DHCP address to appear, then writes the
   host name and every IPv4 address to `/dev/msglog`, so they show on the
   KVM console.
5. Runs `svcadm disable site/homicron-firstboot` so the service never runs
   again. The manifest stays in place as a record.

If DHCP never answers, the script still enables sshd and mDNS, writes
`no DHCP address after 60s` to the console, and disables itself. The person
can then fix the network from the console. The service never goes into
maintenance, because that would hide the console login.

## Stage 3: apply

### Per-host file

`hosts/<name>.env` is a bash file of plain assignments. Every variable has a
default in `bin/homicron` except the first two.

```
HOMICRON_USER=jacob          login to create; required
HOMICRON_UID=501             match the laptop uid, as helios-engvm gen_userdata.sh does; required
HOMICRON_ADDR=               ssh target; default <name>.local
HOMICRON_PORT=22             ssh port; the qemu test VM forwards a high port
SWAP_SIZE=16G                rpool/swap zvol
DUMP_SIZE=16G                rpool/dump zvol
FALCON_DATASET=              zfs dataset for voxel images and disks; empty = rpool default
VOXEL_REF=main               git ref of oxidecomputer/voxel to build
VOXEL_SLEDS=4
VOXEL_SLED_MEMORY_GB=8
```

### Runner

`bin/homicron apply <name>`:

1. Sources `hosts/<name>.env`. A variable already set in the environment
   wins over the file, so private addresses never need to be committed.
   Exits 2 if the file or a required variable is missing.
2. Rsyncs `host/`, `keys/authorized_keys`, and the env file to
   `root@$ADDR:/opt/homicron/` on port `$HOMICRON_PORT`.
3. For each `host/NN-*.sh` in name order, runs one ssh call:
   `ssh root@$ADDR /opt/homicron/run-step.sh NN-name.sh`.
4. Reads the exit status:
   - 0: continue to the next step.
   - 10: the step needs a reboot. Run `ssh root@$ADDR reboot`, wait until
     sshd answers again (poll every 5 seconds, give up after 10 minutes),
     then run the same step again. The step must then exit 0.
   - anything else: print the step's log from the box and exit with that
     status.
5. Prints `apply complete` and the two `voxel image create` commands.

`bin/homicron ssh <name>` opens a shell as `$HOMICRON_USER`. It exists so
the README has one way to reach every box.

Only the runner knows about ordering, reboots, and the laptop. The steps know
nothing about each other.

### run-step.sh

Runs on the box. Sources `/opt/homicron/<name>.env`, exports the variables,
runs the named step with `set -o errexit -o pipefail -o xtrace`, and appends
stdout and stderr to `/var/log/homicron/<step>.log`. Passes the step's exit
status through unchanged.

### Steps

Each step first makes sure of its own end state and exits 0 without acting
when the state is already right. Then it acts. Then it makes sure of the end
state again and exits 1 if the state is still wrong.

| Step | End state | Action when not met |
|---|---|---|
| 10-user.sh | `$HOMICRON_USER` exists with uid `$HOMICRON_UID`, home on `rpool/home/$USER`, `Primary Administrator` profile, `net_icmpaccess` in defaultpriv, authorized_keys in place, `/opt/ooce/bin:/opt/ooce/sbin` in `/etc/default/login` PATH | `zfs create`, `useradd -u -g staff -d -s /bin/bash -P 'Primary Administrator'`, `passwd -N`, `usermod -K defaultpriv=basic,net_icmpaccess`, copy keys, `sed` the PATH line |
| 20-swap-dump.sh | `rpool/swap` and `rpool/dump` zvols exist at the configured sizes, swap is active, `/etc/vfstab` has the swap line, `dumpadm` points at the dump zvol | `zfs create -V`, `swap -a`, append to vfstab, `dumpadm -d` |
| 30-pkg.sh | `pkg update -n` reports nothing to do and `developer/build-essential`, `developer/illumos-tools`, `developer/versioning/git` are installed | `pkg update -v`; if the update created a new boot environment, exit 10; else `pkg install` the three packages |
| 40-rust.sh | `~$USER/.cargo/bin/cargo` runs | as `$USER`: rustup install with `bash` in place of `sh` |
| 50-falcon.sh | `$FALCON_DATASET` exists, or the variable is empty | `zfs create -p` |
| 60-voxel.sh | `~$USER/src/voxel` is at `$VOXEL_REF` and `target/release/voxel` is newer than the checkout | as `$USER`: `git clone` or `git fetch` and `git checkout`, `cargo build --release` |
| 70-voxel-conf.sh | `voxel config get <key>` returns the configured values for `topology.sleds`, `topology.sled_memory_gb`, and `falcon.dataset` when set | as `$USER`: `voxel config set` for each |

The second run of `apply` on a finished box runs every step and changes
nothing. That is the test of idempotence.

## Error handling

- Stage 1 exits before it touches the disk if anything it downloaded is
  missing or fails its checksum.
- Stage 2 never fails its SMF method. It reports to the console and disables
  itself.
- Stage 3 stops at the first failing step and prints that step's log. The
  person fixes the cause and runs `apply` again. Finished steps skip
  themselves.
- The runner treats a lost ssh connection as a failure of the current step,
  except after exit 10, where it waits for the reboot.

## Testing

- CI: `shellcheck` and `bash -n` on every `.sh` file and on the two
  extension-less scripts, on every push. The Pages deploy does not run if
  they fail.
- Stage 3 on a finished box: run `apply` twice. The second run must change
  nothing and exit 0.
- End to end in a VM: `test/qemu.sh` runs on any x86 Linux host with KVM,
  qemu, and OVMF installed. It downloads `helios-install-ttya.iso` from
  `https://pkg.oxide.computer/install/latest/`, creates a 100 GiB qcow2 disk,
  and boots qemu with KVM, OVMF firmware, 8 vCPUs, 16 GiB, a virtio disk, a
  virtio NIC on user-mode networking with DHCP, the serial console on stdio,
  and host port 2222 forwarded to guest port 22. User-mode networking gives
  the guest the address 10.0.2.15 and lets it reach the host at 10.0.2.2, so
  no root or bridge setup is needed on the Linux host. `test/serve.sh` builds
  `_site/` with the same script the workflow uses and serves it on port 8000
  with `python3 -m http.server`, so stage 1 can be tested against the working
  tree before anything is pushed. `hosts/vm.env` sets `HOMICRON_PORT=2222`
  and leaves `HOMICRON_ADDR` empty; the person passes the Linux host's
  address in the environment, so no private host name is committed.
- The VM exercises every stage at native speed, including the voxel build.
  It does not exercise `voxel launch`, which cannot run nested, and it does
  not exercise the IMB-A1002's firmware boot order, the JetKVM virtual media,
  the `rge` driver, or the real disk name. Those four are what is left for the
  physical machine.
- An Apple Silicon Mac cannot run x86 Helios at a useful speed, so the VM
  test runs on the Linux host over ssh.

## Items to confirm on the first real install

These are facts the design assumes. The plan must record the outcome of each
one in the README.

1. `ipadm create-addr -T dhcp` works in the installer ramdisk.
2. The ramdisk's `curl` trusts the GitHub Pages certificate chain. If it does
   not, the fallback is to serve over plain HTTP with the checksums as the
   only integrity check until first boot.
3. Which `svccfg` invocation enables the first-boot service against `/a`.
4. The NIC appears as `rge0` on the IMB-A1002.
5. `network/ssh` is present but disabled on a fresh install, so stage 2 has
   to enable it. If it is already enabled, step 3 of stage 2 is a no-op.

## Out of scope for the first version

- PXE boot. `install-helios` already supports a network-boot mode through
  `/system/boot/install.env.sh`. It would remove the virtual media step for
  the IPMI machines, and it fits the same `_site/` layout, but it needs a
  TFTP and DHCP server on each network.
- Locking down root SSH after the user exists. The machines are lab hosts
  on a trusted network.
- Running `voxel image create` from the runner.
