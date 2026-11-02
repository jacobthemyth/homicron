# The rack at boot

Date: 2026-11-02

A voxel rack does not survive a host reboot. Every host-side object it
depends on is transient, and the VMs die with the host. The topology zvols
and the falcon workspace survive, but a plain `voxel launch` on them fails:
RSS runs again and the sleds' bootstore rejects it as out of date, and the
sleds come back with no control-plane zones. voxel has no resume path. The
only working sequence after a boot is `voxel destroy` then `voxel launch`,
and the rack starts empty. These facts come from the reboot test of
2026-11-02, recorded in
[2026-11-02-rack-readiness-survey.md](2026-11-02-rack-readiness-survey.md).

This document adds one SMF service that rebuilds the rack at every boot,
and the homicron steps that put every piece the rack needs into place, so
that `apply` converges a reinstalled box to the same end state. It assumes
the runner and the apply service described in
[2026-11-02-apply-under-smf-design.md](2026-11-02-apply-under-smf-design.md).
Nothing here changes `bin/homicron` beyond the hosts variable list.

## Goals

- After any boot of the host, the rack is initialized and the console
  answers at `https://recovery.sys.rack1.oxide.test` without a person.
- The rack never launches while an apply is in progress on the box.
- `svcs` shows whether the rack is up, launching, or failed, and
  `svcs -xv` names the log on failure.
- Every setting the launch depends on is a homicron step: `voxel.toml`
  keys, the propolis binary, the network layout, time synchronization.
- A hook runs after each successful launch for commands that recreate rack
  content through the Oxide API. homicron ships the hook point, not the
  content.

## Non-goals

- Preserving rack content across a reboot. voxel cannot do it today.
- Stopping the rack without destroying it. voxel has no stop.
- The workstation's static route and hosts entry. They are a runbook note
  in the README.
- An ARC cap, SMART monitoring, a scrub schedule. Later steps.
- The `net_icmpaccess` privilege for `voxel commtest`. A later step, with
  the deferred finding about `usermod -K` replacing the whole list.
- Removing the viona workaround (step 65).

## Facts the design depends on

Read on homicron00 and in the voxel checkout `a6ad27b` on 2026-11-02.

- falcon spawns each `propolis-server` as a plain child of `voxel launch`
  with the launcher's session and controlling terminal. The VMs die of
  SIGHUP when that terminal closes. A launch with no terminal at all
  (`nohup … < /dev/null &`) leaves them running after the launcher exits.
- `voxel launch` in isolated mode brings the external segment up itself,
  then creates links, boots the VMs, drives RSS, and sets the host route to
  the rack when it runs as root. It prints `launch complete` on success
  and `rack-init FAILED: …` on failure, and exits 0 in both cases.
- `voxel destroy` kills the VMs, removes the links and the topology
  datasets, and deletes the falcon workspace `.falcon/` under the workdir.
  The external segment stays up.
- The workdir is the directory of `voxel.toml`:
  `/home/<user>/.config/voxel`. `.falcon/` and `cargo-bay/` under it are
  owned by root.
- A launch with the images present takes 7 to 12 minutes. RSS has an
  internal budget of 30 minutes.
- falcon downloads `propolis-server` from
  `https://buildomat.eng.oxide.computer/public/file/oxidecomputer/propolis/falcon/<rev>/propolis-server`
  and its digest from the same path with `.sha256.txt`, unless
  `falcon.propolis_binary` is set. The rev is the `propolis-client` `rev`
  in the voxel workspace `Cargo.toml`. The download stalled twice on
  2026-11-02.
- dhcpagent ignores one DHCP option on one interface with
  `<link>.PARAM_IGNORE_LIST=<option>` in `/etc/default/dhcpagent`. Option
  3 is Router. dhcpagent reads the file when a lease starts.
- `svc:/site/homicron-apply:default` is `online` when the box has converged
  and the method is idle, `offline*` while steps run, `maintenance` after a
  failed step. Its method runs at boot only to finish an interrupted apply.
- SMF ignores process exits in a transient service's contract and kills the
  contract when the service is disabled or its start method times out.

## The host layout on homicron00

Both ports are cabled on one LAN. `igb0` carries the default route and is
the isolated segment's NAT uplink. `igb1` is the management address that
`HOMICRON_ADDR` names, with the Router option ignored. The layout is
expressed in the hosts file, not hardcoded:

```
VOXEL_EXTERNAL_MODE=isolated
VOXEL_EXTERNAL_UPLINK=igb0
MGMT_LINKS=igb1
```

## Hosts variables

New rows in `hosts/README.md` and in `host_vars` in `bin/homicron`. The
other spec adds nothing to that list, so the two changes do not collide.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `VOXEL_EXTERNAL_MODE` | no | `lan` | `external.mode` in voxel.toml. `lan` or `isolated`. |
| `VOXEL_EXTERNAL_UPLINK` | when mode is `isolated` | empty | `external.uplink`: the up physical link the segment NATs out of. |
| `VOXEL_CP_IMAGE` | no | empty | `image.cp`. Empty selects the one `voxel-cp-*` image under the dataset. |
| `MGMT_LINKS` | no | empty | Comma-separated links whose DHCP lease must not install a default route. |
| `VOXEL_RACK` | no | `yes` | `yes` enables the rack service, `no` disables it. |

Values follow the existing rule: letters, digits, and `. _ / : @ % + , -`.

## Step 25: network layout and time

`host/25-network.sh`. End state: `chrony` is online, and for every link in
`MGMT_LINKS` the file `/etc/default/dhcpagent` holds the line
`<link>.PARAM_IGNORE_LIST=3` and the link has no default route.

- `check`: `svcs -H -o state chrony` is `online`; each line is present;
  `netstat -rn -f inet` shows no `default` route whose interface is a
  management link.
- `apply`: `svcadm enable -s chrony` when it is not online. For each link
  whose line is missing, append a comment and the line, then recycle the
  lease with `ipadm delete-addr <link>/v4` and
  `ipadm create-addr -T dhcp -w 20 <link>/v4`. The recycle drops the ssh
  session when the runner reaches the box on that link. Under the apply
  service the method keeps running and the runner reconnects, so this is
  safe; the step logs `recycling the lease on <link>, an ssh on it drops`
  first.

An empty `MGMT_LINKS` leaves dhcpagent alone. The step never removes a
line, so a link taken out of `MGMT_LINKS` keeps its rule until a person
removes it; the README says so.

## Step 85: voxel.toml keys

`host/70-voxel-conf.sh` becomes `host/85-voxel-conf.sh` and grows from two keys to seven. Its structure (parallel
`keys` and `values` arrays, `current`, `check`, `apply`) stays.

| Key | Value |
|---|---|
| `topology.sleds` | `VOXEL_SLEDS` |
| `topology.sled_memory_gb` | `VOXEL_SLED_MEMORY_GB` |
| `falcon.dataset` | `FALCON_DATASET`, only when set |
| `image.cp` | `VOXEL_CP_IMAGE`, or the one image found |
| `image.frr` | `voxel-frr-proto` |
| `external.mode` | `VOXEL_EXTERNAL_MODE` |
| `external.uplink` | `VOXEL_EXTERNAL_UPLINK`, only when mode is `isolated` |

The cp image is found with `zfs list -H -o name -r <dataset>/img`, where
the dataset is `FALCON_DATASET` or `rpool/falcon`, filtered to names that
start with `voxel-cp-`. Zero images: the step logs `no voxel-cp image under
<dataset>/img; step 80 builds one` and exits 1. More than one image and an
empty `VOXEL_CP_IMAGE`: the step logs the names and exits 1, because voxel
cannot guess either. The step runs after step 80 so that the image exists.
The test file keeps its name, `test/step-voxel-conf.bats`.

`falcon.propolis_binary` is owned by step 87 below, not by this step,
because its value is a path the step computes.

When `VOXEL_EXTERNAL_MODE` is `isolated` and `VOXEL_EXTERNAL_UPLINK` is
empty, the step exits 1 with `VOXEL_EXTERNAL_UPLINK is required in isolated
mode`.

## Step 87: the propolis binary

`host/87-propolis.sh` follows the voxel checkout, whose `Cargo.toml` names
the rev. End state: `/var/homicron/propolis/<rev>`
exists with mode 0755 and the digest buildomat publishes for that rev, and
`falcon.propolis_binary` in voxel.toml names it.

- The rev: `grep -E '^propolis-client *= .*rev *= *"'` on
  `~/src/voxel/Cargo.toml`, the 40-hex value. A missing or malformed line
  exits 1 with `cannot read the propolis rev from voxel's Cargo.toml`.
- `check`: the file exists, `digest -a sha256` matches the digest file
  `/var/homicron/propolis/<rev>.sha256` saved beside it, and
  `voxel config get falcon.propolis_binary` returns the path.
- `apply`: fetch the digest file first with `curl -fsSL --retry 5
  --retry-all-errors`, then the binary with the same flags plus `-C -`
  into `<rev>.part`, compare, rename, `chmod 0755`, and set the key. A
  digest mismatch deletes the part file and exits 1 with both digests.
- Old revs under `/var/homicron/propolis/` are left in place.

The directory is on the `rpool/homicron` state dataset that `start-apply.sh`
creates. It is outside `/opt/homicron`, which the runner's rsync `--delete`
owns and would empty on every apply, outside the user's home, where `voxel
destroy` deletes `.falcon/bin`, and outside the boot environment, so an OS
update keeps it.

## Step 90: the rack service

`host/90-voxel-rack.sh` installs and enables `svc:/site/voxel-rack:default`.
Three files ship in `host/`: `voxel-rack.xml`, `voxel-rack-start.sh`,
`voxel-rack-stop.sh`.

End state: the manifest at `/lib/svc/manifest/site/voxel-rack.xml` and the
two methods under `/opt/homicron/` match the shipped files, the service is
imported, and it is enabled when `VOXEL_RACK` is `yes` and disabled
otherwise.

The two method scripts need no install step of their own: the runner's
rsync puts every file in `host/` under `/opt/homicron`, which is where
the manifest points.

- `check`: the installed manifest `cmp`s the shipped one; `svcs -H -o
  state site/voxel-rack` prints a state; enabled (`online`, `offline`,
  `offline*`) matches `VOXEL_RACK`.
- `apply`: when the manifest differs or is missing, `svccfg validate`
  (print its output and exit 1 on failure), copy, `svccfg import` (an
  idempotent upgrade as the apply spec describes). Then, when the enabled
  state differs from `VOXEL_RACK`: `svcadm disable` for `no`; for `yes`,
  `svcadm clear` when the service is in `maintenance` (it is enabled
  already, and `enable` would change nothing), else `svcadm enable`. The
  step then waits up to ten seconds for `svcs` to show the new state,
  because `svcadm` returns before startd moves the instance. A converged
  box runs nothing. Any `VOXEL_RACK` value other than `yes` or `no` exits 1
  before anything runs. The step does not wait for the launch: it exits
  once the service is enabled, and the apply log says
  `voxel-rack enabled; the launch runs under svc:/site/voxel-rack, log
  /var/log/voxel-rack.log`. Enabling starts the launch at once on a
  running box, as well as at every boot.

### The manifest

Modeled on `firstboot/homicron-firstboot.xml`.

- `create_default_instance enabled='false'`, `single_instance`.
- Dependencies, both `restart_on='none'`:
  `require_all` on `svc:/milestone/multi-user-server:default` and
  `require_all` on `svc:/site/homicron-apply:default`. There is no
  dependency on `ipfilter`: the launch enables it itself, and a fresh box
  has it disabled, so a dependency would wait forever before the first
  launch.
  The last one is the hold during apply: `homicron-apply` is `online` only
  when the box is converged and idle, so the rack waits for an apply that a
  reboot interrupted, and never launches after a failed apply left the
  service in `maintenance`. `restart_on='none'` keeps a running rack alive
  while a later `apply` restarts `homicron-apply`.
- Start method `/opt/homicron/voxel-rack-start.sh`,
  `timeout_seconds='2400'`. The launch's own RSS budget is 1800 s, and a
  destroy comes first.
- Stop method `/opt/homicron/voxel-rack-stop.sh`, `timeout_seconds='600'`.
- `startd/duration` is `transient`.
- A `method_context` is not used: the methods run as root and switch to
  the login user themselves, as the steps do.

### The start method

`voxel-rack-start.sh` runs as root with `set -o nounset -o pipefail` and no
`errexit`. Its output goes to `/var/log/voxel-rack.log`, appended, with a
`=== start <UTC time>` header, and SMF's own method log keeps the exit
status.

1. Source `/opt/homicron/host.env` with `allexport`. `voxel` is
   `/home/$HOMICRON_USER/src/voxel/target/release/voxel`, and every voxel
   command below runs as `su - $HOMICRON_USER -c "pfexec $voxel …"`, so
   the user's `voxel.toml` applies.
2. If `/home/$HOMICRON_USER/.config/voxel/.falcon` exists, run
   `voxel destroy`. Log `destroying the previous rack`. A nonzero exit is
   logged and the method continues, because a half-destroyed topology is
   what launch's preflight reports better.
3. Run `voxel launch` with stdin from `/dev/null`, stdout and stderr
   appended to the log, and no terminal. The RSS progress lines are the
   log's main content, so `--no-progress` is not used. SMF methods have no controlling
   terminal, so the VMs survive the method's exit.
4. Read the result from the launch output: `launch complete` without a
   `rack-init FAILED` line is success. On failure, log
   `launch failed; see above` and exit 95 (`SMF_EXIT_ERR_FATAL`, as
   `apply.sh` does), which puts the service straight into `maintenance`.
   A missing `host.env` exits 96 before anything runs. SMF kills the contract, which takes the VMs down; the
   next `svcadm clear` starts over from step 2.
5. On success, if `/home/$HOMICRON_USER/.config/voxel/post-launch.sh`
   exists and is executable, run it as `$HOMICRON_USER` with the log as
   output, under `timeout 600`. Its exit status is logged (`timed out` for
   124), and does not change the service's. The rack is up either way; a
   broken or hanging hook must not take it down, and without the bound a
   hanging hook would hit the method timeout, whose contract kill takes
   the VMs with it.
6. Exit 0. The service is `online`, which means the rack answered RSS.

### The stop method

`voxel-rack-stop.sh`: source `host.env`, run `voxel destroy` as the user
when `.falcon` exists, exit 0. SMF then kills anything left in the
contract. `svcadm disable site/voxel-rack` therefore removes the rack, and
`svcadm restart` rebuilds it. A host shutdown runs the stop method too,
which makes the VMs exit cleanly before the host does.

### The hook

`post-launch.sh` is a file the operator owns. homicron does not create,
ship, or version it. The README gives a two-line example that logs in with
the `oxide` CLI and creates a project, and names where the recovery
credentials come from. The hook runs after every launch, so it must be
safe to run against an empty rack each time.

## Step order after this change

```
10-user  20-swap-dump  25-network  30-pkg  40-rust  50-falcon  60-voxel
65-viona-workaround  80-voxel-images  85-voxel-conf  87-propolis  90-voxel-rack
```

Step 25 runs before step 30 so that the box reaches the reboot in step 30
with chrony on and the layout settled. The lease recycle in step 25 can
drop the runner's ssh; the apply service makes that harmless.

## Failure and edge cases

- Boot with no apply in flight: `homicron-apply` goes `online` within
  seconds, `voxel-rack` starts, the rack is up about ten minutes later.
- Boot after a step-30 reboot: `homicron-apply` is `offline*` until the
  apply completes, then `voxel-rack` starts. The images step may run first;
  the rack waits for it.
- A failed apply: `homicron-apply` is `maintenance`, `voxel-rack` stays
  `offline` with the dependency unsatisfied. `svcs -xv` says why. The
  next `apply` clears it and the rack follows.
- `homicron-apply` disabled by hand: `voxel-rack` waits forever. The
  README says so; `svcadm enable site/homicron-apply` is the fix.
- A launch that fails RSS: `maintenance`. The log holds voxel's output.
  `svcadm clear site/voxel-rack` retries from destroy.
- The start method's timeout: 2400 s. A launch that hangs past it is killed
  with its VMs and the service goes to `maintenance`.
- `VOXEL_RACK=no`: the step disables the service, which destroys a running
  rack. The README says so.
- The step files for the methods change on a later `apply` while a rack is
  up: `svccfg import` updates the manifest, the method files are copied,
  and nothing restarts. The new methods are used at the next start or stop.
- Someone runs `pfexec voxel destroy` by hand while the service is online:
  the service stays `online` with no rack. `svcadm restart` fixes it.
  The README says to use `svcadm` for the rack's lifecycle.
- Memory: 4 sleds with 8 GB each leave about 4 GB free on a 128 GB host
  once the ARC has grown. The ARC yields under pressure. An ARC cap is a
  later step.

## Migration on homicron00

The box already has `voxel.toml` with the image keys, isolated mode, the
uplink, and `falcon.propolis_binary` pointing into `~/bin`. Step 85 finds
every key already set except that its own value for `image.cp` matches.
Step 87 downloads the same rev to `/var/homicron/propolis/` and repoints
`falcon.propolis_binary`; the copy in `~/bin` can be deleted by hand. Step
25 finds the dhcpagent line present and chrony online. Step 90 installs and
enables the service, which destroys the running rack and relaunches it
once, about ten minutes. The reboot test is then a plain `pfexec reboot`
and a console login.

## Documentation

- README "Install a machine": after `apply complete`, the rack launches
  under `svc:/site/voxel-rack` and comes back after every boot, empty. The
  console address, the HTTPS note, the credentials, the workstation route
  and hosts entry, and the `post-launch.sh` example. `svcs -xv
  site/voxel-rack` and `/var/log/voxel-rack.log` for a failed launch.
  `svcadm disable` destroys, `svcadm restart` rebuilds.
- README "What the stages do": the new steps and files.
- `hosts/README.md`: the five variables, the `MGMT_LINKS` note about
  removed links, and that `VOXEL_RACK=no` destroys a running rack.
- `hosts/homicron00.env`: the three layout lines, unless the file stays
  private; it is gitignored, so the README example carries them.

## Testing

bats with fakes, as the existing steps.

- `test/step-network.bats`: chrony enabled only when not online; a line
  per management link, appended once; recycle runs per missing line only;
  the default route check; empty `MGMT_LINKS` touches nothing.
- `test/step-voxel-conf.bats`: the seven keys; one image found; zero and
  two images exit 1 with the messages; `VOXEL_CP_IMAGE` wins; isolated
  without an uplink exits 1; `lan` sets no uplink.
- `test/step-propolis.bats`: the rev is read from a fake `Cargo.toml`;
  digest match skips; mismatch deletes the part and exits 1; both curl
  calls carry `--retry`; the key is set.
- `test/step-voxel-rack.bats`: validate failure exits before copy; import
  only when the manifest differs; enable or disable by `VOXEL_RACK`; a
  converged box runs nothing.
- `test/voxel-rack.bats` (start): destroy only when `.falcon` exists; the
  launch runs as the user with stdin from `/dev/null`; `launch complete`
  exits 0; `rack-init FAILED` exits 95; a missing `host.env` exits 96; the hook runs only on success and
  only when executable; a failing hook leaves exit 0.
- `test/voxel-rack.bats` (stop): destroy when `.falcon` exists, exit 0
  either way.
- `test/lint.sh` lists the new scripts; `xmllint --noout` the manifest.
- The qemu rehearsal covers steps 25, 85, 87, and 90 with no rack: step 90
  enables the service, whose launch fails the memory preflight in the VM
  and leaves `maintenance`. The real test is `reboot` on homicron00 and a
  console login.
