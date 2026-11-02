# homicron00: rack readiness survey and plan

Date: 2026-11-02. Surveyed over ssh after `apply homicron00` and both image
builds finished.

## The finding that changes the goal

voxel cannot run virtual machine instances on its emulated sleds. The sleds
are themselves bhyve guests, and bhyve does not nest. The voxel operator guide
states this in its introduction and again under "Running Workloads": workloads
on a voxel rack are probes, which are zones that attach to a VPC, not VMs.

This means that the Oxide API on this rack can create projects, VPCs, disks,
images, silos, and probes, but `oxide instance create` followed by a start will
fail on the sled. A NAS as a VM on the rack is not possible with voxel today,
on any hardware. The constraint is in the emulation, not in the host.

The rest of this document plans the rack that voxel can give you: a complete
Oxide control plane with the web console, the API, external DNS, Oximeter
telemetry, SoftNPU switches, BGP routers, and probes as workloads. Section 6
lists the options for real VMs.

## 1. State of homicron00

Hardware and operating system.

- ASRock Rack AM5D4ID2, AMD EPYC 4545P (16 cores, 32 threads), 128 GB.
- One Corsair MP600 PRO NH 4 TB NVMe. `rpool` is a single-disk pool, 49 GB
  used, 3.44 TB free, no errors, no scrub ever run.
- Helios 3.0.24365, current. Boot environment `helios-2` is active, created at
  23:17 today by step 30. Three older boot environments remain.
- `igb1` holds 192.168.0.154 by DHCP plus SLAAC IPv6. `igb0` is uncabled and
  shows a DHCP address object in state `inaccessible`.
- Memory at idle: 73 GB free, 41 GB in the ZFS ARC, 10 GB kernel.
- `vmm` and `viona` are loaded. `/etc/system` carries the step 65 mask.
- Swap and dump zvols exist, 16 GB each. `dumpadm` is configured.
- `chrony` is installed but disabled. The host has no time synchronization.
- `ipfilter` is disabled. sshd allows root with keys only. mDNS is on.
- Zone brands installed: `ipkg`, `lipkg`. Available but not installed:
  `bhyve`, `lx`, `omicron1`, `sparse`, `illumos`, `pkgsrc`.

voxel.

- Checkout `a6ad27b` ("Pin omicron to 77901ac4"), release binary built.
- Images: `voxel-cp-77901ac4bb2d6e1ac6dd7380b3758129b73f69cd` (10.2 GB) and
  `voxel-frr-proto` (1.3 GB), both under `rpool/falcon/img`.
- No `voxel.toml` exists. Step 70 only writes keys whose values differ from
  the defaults, and `VOXEL_SLEDS=4` and `VOXEL_SLED_MEMORY_GB=8` are the
  defaults, so it wrote nothing.
- Because `image.cp` is unset, `voxel info` names the image `voxel-cp-proto`,
  which does not exist. `pfexec voxel launch` would fail today.
- No rack was ever launched: no zones, no VNICs, no etherstubs, empty
  `rpool/falcon/topo`, no falcon propolis binary downloaded yet.
- The omicron checkout under `~/voxel-builds` is 9.6 GB.

## 2. What a working rack looks like

The default topology is 4 sleds (`g0`-`g3`, `g0` and `g3` run the SoftNPU
switch zones) and 3 FRR routers (`ce`, `cr1`, `cr2`). Guest memory is 44 GB.
voxel's preflight budgets 1.2 times that plus 22 GB for the kernel and ARC,
about 75 GB, which leaves about 53 GB on this host. The floor is 3 sleds, the
trust-quorum minimum, at 36 GB guest memory.

In the default `lan` mode every sled and router has an external NIC on
`igb1`, so the home router hands out 7 more DHCP leases. The rack announces
198.51.100.0/24 through `ce`. The host gets a route to that prefix from
`voxel route`. A workstation needs its own static route through the host:

```
sudo route add -net 198.51.100.0/24 192.168.0.154
```

The console and API are at `http://recovery.sys.rack1.oxide.test`, resolved
by the rack's external DNS at 198.51.100.20, with login `recovery` and
password `oxide`. There is no TLS unless a certificate is supplied at rack
setup.

A launch takes a few minutes after the VMs boot. `voxel destroy` deletes all
rack state. There is no stop or start command. The VMs are propolis processes
started by falcon, not SMF services, so a host reboot ends the rack. Whether
`launch` can resume a rack whose zvols still exist, or whether the only path
is `destroy` then `launch`, is not documented. This is the first thing to find
out, because it decides how much of the lifecycle needs automation.

## 3. Gaps, in the order to close them

| # | Gap | Why it matters | Fix |
|---|---|---|---|
| 1 | `image.cp` and `image.frr` unset | launch fails | `voxel config set image.cp voxel-cp-77901ac4…` and `image.frr voxel-frr-proto`; then make step 70 select the one cp image under the dataset so a reinstall converges |
| 2 | rack never launched | the whole stack is unproven on this host and NIC | first launch by hand, watch RSS, log in to the console |
| 3 | host has no NTP | CockroachDB inside the rack is clock-sensitive, and host and guest clocks drift apart | enable `chrony` (new step; the stock `chrony.conf` already names `pool.ntp.org`) |
| 4 | reboot behavior unknown | decides the lifecycle runbook | reboot the host once with a rack up and record what `launch`, `status`, and `destroy` do |
| 5 | step 30 reboots the box during `apply` | killed an image build today; would kill a running rack | refuse `pkg update` or the reboot while a rack topology exists, or make it opt-in |
| 6 | commtest privilege | `voxel commtest` is the one built-in workload and it needs `net_icmpaccess` | add the privilege in step 10, which already owns `usermod -K`; the deferred finding about `-K` replacing the whole list applies here |
| 7 | workstation route and DNS | the console is unreachable from the Mac without them | runbook; optionally a `bin/homicron route <name>` helper |
| 8 | no scrub, no SMART, no disk redundancy | a single 4 TB NVMe holds the rack and every image | monthly `zpool scrub` cron, `smartmontools` from the repo, and a second NVMe as a mirror when budget allows (README already covers the attach) |
| 9 | 7 DHCP leases on the LAN, `ce` address read over serial every launch | slow launch and a moving nexthop | set `topology.ce_external_ip` to a reserved LAN address, or move to `isolated` mode on `igb0` once it is cabled |
| 10 | viona mask | the mask disables a virtio feature for every guest on the host | remove step 65 when voxel pins a propolis at or past `6588611` |
| 11 | `igb0` DHCP object `inaccessible` | mDNS advertises `0.0.0.0` | the queued firstboot fix: DHCP only on links that are up |
| 12 | tooling debt | 22 deferred review findings and 4 queued improvements | fix in a batch against the qemu VM |

## 4. Automation or runbook

Automation (a homicron step) fits state that must converge and survive a
reinstall: image selection in `voxel.toml`, `chrony`, the commtest privilege,
the scrub cron, the apply-time guard. Each is a check and an apply.

A runbook fits the rack lifecycle: launch, route, console login, destroy, and
whatever the reboot test shows. Launch is long, interactive, and stateful.
Automate it only after the runbook has run by hand at least twice and the
reboot behavior is known. A thin `bin/homicron rack launch|status|destroy`
wrapper is then a small step.

## 5. Phases

Phase 0, today, by hand, about one hour. Set the two image keys. Enable
`chrony`. Run `pfexec voxel launch` from a tmux session on the host. Add the
route on the Mac, resolve the console address, log in. Create a project and a
probe through the API. This proves the rack and produces the runbook.

Phase 1, the reboot test. With the rack up, reboot the host. Record what
survives and what `launch` does. Write the lifecycle runbook from the result.

Phase 2, convergent steps in homicron: step 70 selects the cp image; new step
for `chrony`; step 10 grants `net_icmpaccess`; a scrub cron; the guard in
step 30 and the runner. Rehearse against the qemu VM, then `apply` to
homicron00 while no rack is running.

Phase 3, operations: `ce_external_ip` or isolated mode, SMART, the mirror
disk, the viona step removal when upstream moves.

Phase 4, tooling debt: the 22 deferred findings and the 4 queued
improvements.

## 6. Options for real virtual machines

voxel will not run them on the rack. The choices are:

1. Run VMs on the Helios host beside the rack, as `bhyve` brand zones or
   with propolis-standalone. The host has about 53 GB left with 4 sleds, or
   63 GB with 3. These VMs are outside the Oxide API and console.
2. Treat the rack as a lab for the control plane only and run workloads on a
   different machine.
3. Wait for upstream. Nested bhyve is not on any public roadmap found during
   this survey, so do not plan on it.

The choice is yours. Nothing in phases 0 to 4 depends on it.

## 7. Decisions taken on 2026-11-02

4 sleds. Isolated mode. No VMs on the host. Everything that a reboot loses
must come back without a person.

## 8. What phase 0 and phase 1 found

The first launch and the reboot test ran on 2026-11-02 between 16:00 and
18:00 UTC. The facts below replace guesses in sections 2 and 3.

Host network layout. Both ports are cabled on the one LAN. `igb0`
(192.168.0.12) holds the only default route and is voxel's NAT uplink.
`igb1` (192.168.0.154) is management only: the line
`igb1.PARAM_IGNORE_LIST=3` in `/etc/default/dhcpagent` makes dhcpagent ignore
the Router option on that interface. Two default routes on one LAN would
send half of the NAT traffic out the wrong port. The layout survived the
reboot. `igb0/v4` had no entry in `/etc/ipadm/ipadm.conf` and vanished once
mid-launch; it was recreated persistently. The cause is unknown.

Launch mechanics.

- falcon spawns every `propolis-server` as a plain child of `voxel launch`.
  The VMs inherit the controlling terminal and die of SIGHUP when it closes.
  A `screen -dmS` launch killed the rack the moment the launcher exited.
  The working form has no terminal at all:
  `nohup pfexec voxel launch > log 2>&1 < /dev/null &`.
- falcon downloads `propolis-server` from buildomat on the first launch.
  The download stalled twice. The binary now lives at
  `~/bin/propolis-server-5e201ec4…` and `falcon.propolis_binary` points at
  it, which skips the download.
- `voxel route` needs `pfexec`. Unprivileged it logs
  "insufficient privileges" and adds nothing. `launch` sets the route itself
  when it runs as root.
- A launch takes about 7 minutes from start to "launch complete" with the
  images already built.
- The console is HTTPS, not HTTP. voxel's commission step posts a
  self-signed wildcard certificate for `*.sys.rack1.oxide.test`, and Nexus
  listens on 443 only. A connection without the right server name gets a
  TLS access-denied alert. `https://recovery.sys.rack1.oxide.test`,
  login `recovery`, password `oxide`. Nexus addresses 198.51.100.22 to .24.
- Memory with the rack up: 45 GB VMM, 17 GB kernel, 61 GB ARC, 4 GB free.
  The ARC grows into everything that is left. A cap is worth setting.

Reboot behavior. Every host-side object is transient and disappears: 36
VNICs, 28 simnets, the etherstub and its address, both NAT rules, both
routes, all seven VMs. The 38 topology zvols and the falcon workspace
survive. A plain `voxel launch` on the surviving topology recreates the
links and boots the VMs, but RSS runs again, and the sleds still hold the
old bootstore, so it fails with "Network config update failed because it is
out of date. Attempted update generation: 1, current generation: 3". The
sleds come back with no control-plane zones. The rack does not self-heal and
voxel has no resume path. After a host reboot the only working sequence is
`voxel destroy` then `voxel launch`, and the rack starts empty.

Consequence: rack content (projects, silos, IP pools, images, probes) is
lost on every host reboot. If content must come back, something must
recreate it through the Oxide API after each launch.

## 9. Design: a boot-time rack service

Goal. After any host boot the rack is up and reachable without a person,
and the pieces that make that possible are converged by `apply` so a
reinstall gets them back.

Components, each one homicron step.

1. Step 70, extended. `voxel.toml` gets `image.cp` (the one
   `voxel-cp-*` image under the dataset, or `VOXEL_CP_IMAGE` if set),
   `image.frr`, `external.mode`, `external.uplink`, and
   `falcon.propolis_binary`. New hosts variables `VOXEL_EXTERNAL_MODE`
   (default `lan`) and `VOXEL_EXTERNAL_UPLINK`.
2. Step 72, new: propolis binary. Reads the propolis rev from the voxel
   checkout's `Cargo.toml`, downloads `propolis-server` and its
   `.sha256.txt` from buildomat to `/opt/homicron/propolis/<rev>`, checks
   the digest, and sets `falcon.propolis_binary`. Idempotent on the digest.
3. Step 25, new: network layout. For each link named in `MGMT_LINKS`,
   writes `<link>.PARAM_IGNORE_LIST=3` to `/etc/default/dhcpagent` and
   recycles that link's lease. Enables `chrony`. Makes sure every cabled
   link has a persistent DHCP address object.
4. Step 80, new: the SMF service `svc:/site/voxel-rack:default`.
   Manifest and method script shipped from `host/`. Dependencies:
   `milestone/network`, `system/filesystem/local`, `network/ipfilter`.
   `duration=transient`, start timeout 1800 s. The start method, as root,
   runs as `HOMICRON_USER`'s voxel: `voxel network external up` when the
   mode is isolated, `voxel destroy` when a topology exists, then
   `voxel launch` inside `ctrun -l none -o noorphan nohup …` so the VMs
   live in their own contract and SMF never kills them, then waits for
   "launch complete" in the log, then runs
   `~/.config/voxel/post-launch.sh` if it exists and is executable, and
   exits 0. A failed launch exits 1 and SMF puts the service in
   maintenance, which `svcs -xv` shows. The stop method runs
   `voxel destroy`. Logs go to `/var/log/voxel-rack.log`.
5. Runner guard. `apply` refuses to run step 30 while
   `svc:/site/voxel-rack` is online unless `HOMICRON_ALLOW_REBOOT=1`, and
   prints why.
6. Post-launch hook, optional. `post-launch.sh` is yours: a place for
   `oxide` CLI commands that recreate projects, pools, and probes. homicron
   ships nothing in it.

Not in this design. ARC cap (phase 3, one line in `/etc/system`). The Mac's
static route and hosts entry (a runbook note, or a launchd job later).
Removing step 65 when upstream moves.

Testing. bats tests with fakes for the new steps as for the existing ones.
Rehearsal in the qemu VM covers the steps but not a rack. The real test is
`reboot` on homicron00 and a console login about ten minutes later.


- 4 sleds (default, the tested topology) or 3 (more host memory free).
- `lan` mode on `igb1` as today, or `isolated` mode on a cabled `igb0`.
- Whether option 1 in section 6 is wanted on this host.
