# Apply under SMF

Date: 2026-11-02

`bin/homicron apply` runs each host step over its own ssh connection and
loops on the workstation. That loop is the only thing that orders the steps,
and nothing on the box knows that an apply is in progress. On 2026-11-02 two
applies ran at once against homicron00: one rebooted the box from step 30
while the other was inside rustup, and later a full apply rebooted the box
under a 45-minute voxel image build that the README tells the operator to
run by hand after `apply complete`. A Ctrl-C on the workstation leaves the
current step running on the box for the same reason: the box has no idea
the runner left.

This document moves the loop to the box as one SMF transient service,
`site/homicron-apply`. SMF runs one instance of a method at a time, keeps
the method alive when ssh goes away, restarts it at boot, and records its
state. That removes the need for a lock, for Ctrl-C propagation, and for a
special detached build: the image build becomes an ordinary step inside the
loop. The runner ships files, starts the service, and streams its log. The
designs in [2026-10-31-homicron-design.md](2026-10-31-homicron-design.md)
and later specs still hold for everything not named here.

## Goals

- One apply at a time per box, enforced by the box, with a second runner
  attaching to the running one instead of starting another.
- An apply survives a dropped ssh, a closed laptop, and Ctrl-C; the next
  `apply` rejoins it and shows the output it missed.
- The voxel images are built by a step, so `apply complete` means the box
  is ready to use.
- A reboot requested by a step is carried out by the box, and the apply
  resumes on its own after the boot.
- The runner's user-visible behavior is otherwise unchanged: hosts files,
  keys, the resolved `host.env`, the unreachable message, and the exit
  status of a failed step.
- Every change is covered by a bats test, and the whole flow by the qemu
  rehearsal.

## Non-goals

- One SMF service per step. The steps stay shell scripts run in order by
  one method; SMF dependencies are not used to order them.
- Running the apply at every boot. A boot runs the method only to finish an
  apply that a reboot interrupted.
- A `homicron status` or `homicron log` subcommand. `apply` is how you
  rejoin a run.
- Changing `install/install.sh` or the first-boot service.

## The service

`host/homicron-apply.xml` defines `svc:/site/homicron-apply:default`, a
transient service modeled on `firstboot/homicron-firstboot.xml`:

- `create_default_instance enabled='false'`, `single_instance`.
- One dependency, `require_all` on `svc:/milestone/multi-user-server:default`
  with `restart_on='none'`, so the network, local filesystems, and the
  user's home are up when the method runs at boot.
- Start method `/opt/homicron/apply.sh` with `timeout_seconds='0'`. Stop
  method `:true`.
- `startd/duration` is `transient`.
- The FMRI never changes. A renamed service would leave the old one in the
  repository until someone deleted it.

The manifest ships inside `host/` with every rsync. `start-apply.sh` copies
it to `/lib/svc/manifest/site/homicron-apply.xml` and imports it on every
apply, not only when the service is missing. `svccfg import` is an
idempotent upgrade: it rewrites the properties the manifest defines, keeps
`general/enabled` and a running method, and applies the change at the next
start. That is the same merge the system's `manifest-import` service
performs at boot for every file under `/lib/svc/manifest`.

## The method: `host/apply.sh`

`apply.sh` replaces `host/run-step.sh`. It is the start method and runs as
root under SMF with `set -o nounset -o pipefail` and no `errexit`, so a
failing step is handled rather than killing the method:

1. Source `$HOMICRON_DIR/host.env` with `allexport`, as `run-step.sh` does,
   and export `HOMICRON_DIR`.
2. If the marker `/var/homicron/apply-requested` is absent, exit 0 at once.
   This is the boot case with no apply in flight. A missing `host.env`
   logs and exits 96 (`SMF_EXIT_ERR_CONFIG`).
3. Append a run header to `/var/homicron/apply.log`:
   `=== run <UTC time>` on the first run of an apply, with ` (resumed after
   reboot)` when the boot time recorded in the marker differs from the
   kernel's current boot time.
4. For each `$HOMICRON_DIR/[0-9][0-9]-*.sh` in order: print `==> <step>`
   to the log, run `bash -x <step>` with its output appended to both
   `/var/log/homicron/<step>.log` (with the dated header as today) and
   `apply.log`, and read the status.
   - Status 0: next step.
   - Status 10: rewrite the marker as `<boot time> <step>`, log
     `rebooting for <step>`, and run `reboot`. The method does not return;
     the marker makes the method run again at boot, where the same step
     runs again. If that step asks for a reboot a second time in a row (the
     marker already names it), it is failed with `step <step> failed with
     status 10 (asked for a second reboot)` instead, so a step that never
     settles cannot reboot the box forever. The method sleeps 3 seconds
     between the `rebooting for` line and `reboot`, so the watcher, which
     polls once a second, reads the line before the reboot kills it.
   - Any other status: log `step <step> failed with status <N>` and exit
     95 (`SMF_EXIT_ERR_FATAL`). SMF puts the service in `maintenance` at
     once; a plain exit 1 would make startd retry the method.
5. After the last step, delete the marker, log `apply complete`, and exit 0.
   The service is `online`, which means converged.

The log lines `rebooting for <step>`, `step <step> failed with status <N>`,
and `apply complete` are the protocol the runner reads. Their format is
fixed by the tests in `test/apply.bats` and `test/homicron.bats`.

`/var/homicron` holds the marker and `apply.log` and is its own dataset,
`rpool/homicron`, which `start-apply.sh` creates when missing. It must be
outside the boot environment: `pkg update` clones the root before step 30
asks for a reboot, so a marker or log line written to the root after the
clone is absent in the new boot environment, which would disarm the
second-reboot guard and make the runner's line offset overshoot. The
per-step logs stay in `/var/log/homicron`, created by `apply.sh`.

## Starting a run: `host/start-apply.sh`

The runner calls `start-apply.sh` once over ssh after the rsync. It prints
one line saying what it did and exits 0, or prints the reason and exits
nonzero before changing anything:

1. `svccfg validate /opt/homicron/homicron-apply.xml`. On failure, print
   the validator's output and exit 2.
2. Create `rpool/homicron` mounted at `/var/homicron` when missing,
   `mkdir -p /lib/svc/manifest/site /var/homicron`, copy the manifest into
   place, `svccfg import` it.
3. Write the kernel boot time (`kstat -p unix:0:system_misc:boot_time`)
   to `/var/homicron/apply-requested`.
4. Read the state with `svcs -H -o state site/homicron-apply` and act:
   - `offline` (waiting for dependencies, as during boot), `offline*`
     (method running), or any state with a trailing `*` (startd is moving
     it): print `an apply is already running on the box` and exit 0
     without touching the service. The runner normally never reaches this,
     see below, but two runners can race here and the second must not
     restart the first.
   After each `svcadm` below, poll the state up to 40 times at 0.25 s until
   it differs from what it was: `svcadm` returns before startd acts, and a
   watcher that read the old settled state would call the run finished.
   - `maintenance`: `svcadm clear site/homicron-apply`, print `cleared
     the failed run and started`.
   - `disabled` or `uninitialized`: `svcadm enable site/homicron-apply`,
     print `enabled and started`.
   - `online`: `svcadm restart site/homicron-apply`, print `restarted`.
   - Anything else: print the state and exit 1.

## Watching a run: `host/watch-apply.sh <line-count> <max-seconds>`

The runner streams the log through one remote script, so the ssh carries
only log lines. `watch-apply.sh N MAX` loops once a second:

1. Count the lines of `/var/homicron/apply.log` and print exactly lines
   N+1 through that count (a missing log, or N past its end, prints
   nothing; a line still being written waits for the next pass), then set
   N to the count.
2. Read the service state. While it is `offline`, `offline*`, any state
   with a trailing `*`, or the service is not yet imported, sleep 1 and
   repeat, and exit 4 once MAX seconds of polling have passed. `online`:
   exit 0. `maintenance`: exit 1. Any other state: print `service is
   <state>` and exit 3.

The runner passes the number of lines it has already printed, so a
reconnect after a reboot or a dropped connection shows each line once.
Lines are the unit because `apply.log` is append-only and every writer ends
its output with a newline (`bash -x` does; a step's partial last line is
completed by the `==>` or status line that follows it).

## The runner: `bin/homicron apply <name>`

`load_host`, `write_resolved_env`, `collect_keys`, the `ssh_opts`
keepalives, `unreachable`, and `homicron ssh` are unchanged. The step loop,
`run_step`, `step_failed`, and the post-apply build hint are removed.
`reboot_box` is split: the part that sends `reboot` goes away, and the wait
becomes `wait_for_box`. The new `apply`:

1. Ask the box for the service state. If the method is running, print
   `an apply is already running on the box since <time>; attaching, nothing
   was shipped` (the time is `svcs -o stime`) and go to step 4 with a line
   count one less than the line number of the last `=== run` line in the
   log (read with one `grep -n`), so the header is the first line shown.
   When the service is not running, the runner reads the log's line count
   before starting, so only the new run is streamed and no past run is
   replayed. A box without the service
   yet answers with an error from `svcs`; that counts as not running.
2. rsync `host/`, `host.env`, and `authorized_keys` as today.
3. Run `start-apply.sh` over ssh and print its line. A nonzero exit is a
   runner error with that output.
4. Watch: run `watch-apply.sh <n>` over ssh, print each line as it
   arrives, and count the lines. Then act on the exit status:
   - 0: exit 0. The method's own `apply complete` line was the last line
     streamed, so the runner adds nothing.
   - 1: take `<step>` and `<N>` from the last `step ... failed with
     status` line seen, print `step <step> failed with status <N>` to
     stderr, and exit with `<N>` as today. The step's own output was
     already streamed, so the log is not printed again.
   - 255: the connection dropped. Wait up to `HOMICRON_REBOOT_TIMEOUT`
     for the box to answer again: after a `rebooting for <step>` line that
     means a new boot time, otherwise the first answer; then return to
     step 4 with the current count. Past the deadline, die with `cannot
     reach <addr> after <N>s; the apply continues on the box, rejoin with
     homicron apply <name>`. The `unreachable` message is reserved for the
     first ssh, before anything is shipped.
   - Anything else: die with `watch-apply.sh exited <status>; the log is
     /var/homicron/apply.log on the box`.
   - 4: die with `apply still running after <N>s; rejoin with homicron
     apply <name>` and exit 1. The method on the box continues.
5. `HOMICRON_APPLY_TIMEOUT` (default 7200 seconds) is the MAX the runner
   passes to `watch-apply.sh`, so the bound lives on the box, where a
   blocking ssh cannot be interrupted by the runner's own clock.

Ctrl-C on the runner kills the ssh and the runner; the method continues.
The next `apply` finds it running and attaches. This is the documented way
to leave and rejoin a run.

## Step 80: the voxel images

`host/80-voxel-images.sh` follows the step pattern in `lib.sh`:

- `voxel` is `$home_root/$HOMICRON_USER/src/voxel/target/release/voxel`.
- `check`: `as_user "$voxel image list"` names both `voxel-cp-` and
  `voxel-frr-proto` images. The cp image name carries omicron's commit, so
  the check matches the prefix `voxel-cp-` and the exact name
  `voxel-frr-proto`.
- `apply`: `as_user "pfexec $voxel image create"` when no `voxel-cp-`
  image exists, then `as_user "pfexec $voxel image create-frr proto"` when
  `voxel-frr-proto` is missing. Each runs only when its image is missing,
  so a failed second build does not redo the first. `su - $HOMICRON_USER`
  now has the login PATH from step 10's `/etc/default/su` change, which
  `voxel image` needs for `zfs`.
- The step prints nothing of its own beyond `lib.sh`'s lines; voxel's own
  progress goes to the log through `bash -x`.

Step 65 already warns when the voxel checkout is not the validated commit;
step 80 adds nothing to that.

## Failure and edge cases

- A fresh box has no service. `start-apply.sh` imports the manifest and
  `svcadm enable` starts it; `install/install.sh` needs nothing new.
- The runner's `watch` carries the remote exit status on a sentinel line,
  because the workstation's bash 3.2 cannot `wait` on a process
  substitution.
- A failed step leaves the marker in place and the service in
  `maintenance`. SMF keeps `maintenance` across reboots, so a hand reboot of
  a broken box runs nothing until the next `apply` clears it.
- A box that reboots mid-apply resumes at boot and converges with no runner
  attached. The log records this with the `(resumed after reboot)` header.
- `svcadm restart` of a converged service is cheap: every step skips
  itself. The two image builds skip themselves on `check`.
- Two runners racing to `start-apply.sh`: the second sees `offline*` and
  attaches without restarting. Its rsync may have replaced step files under
  the running method. Steps are small scripts read at start by `bash`, and
  the two runners ship the same `main` in practice; the race is documented,
  not fenced.
- A `watch-apply.sh` that exits 3 names the state. `degraded` cannot occur
  for a transient service; `disabled` while watching means someone ran
  `svcadm disable` by hand, and the message says so.
- The reboot wait already handles a box whose boot time cannot be read.
- `apply.sh` must never be run by hand outside SMF while the service is
  running; the README says to use `svcadm`.

## Migration

homicron00 has every step done and both images present. The first `apply`
with the new runner imports the service, enables it, runs steps 10 to 70 as
no-ops, and step 80 finds both images. `run-step.sh` is removed from `host/`
by the rsync `--delete`. The qemu rehearsal is the full flow: install, apply
with a reboot from step 30 and a Ctrl-C during step 40, rejoin, and watch
the run through step 80 (the images take 30 to 45 minutes there too; the
rehearsal may stop after step 80 starts if time is short, since the step
pattern is covered by bats).

## Documentation

- README "Install a machine": step 6 says `apply` runs every step on the
  box as an SMF service, builds the voxel images, and can be left with
  Ctrl-C and rejoined with the same command. Step 7 (build the images by
  hand) is removed. The layout table gains `host/apply.sh`,
  `start-apply.sh`, `watch-apply.sh`, and `homicron-apply.xml`, and names
  the service and its log.
- README "Known issue" for viona is unchanged.
- `hosts/README.md`: a line that `apply` attaches to a running apply rather
  than starting a second one.
- `bin/homicron` header comment: the runner ships files and watches
  `site/homicron-apply`.

## Testing

- `test/apply.bats`: marker absent exits 0 and runs nothing; runs steps in
  order with `==>` lines and per-step logs; exit 10 logs `rebooting for`
  and calls the faked `reboot` once, no later step runs; a failing step
  logs `step X failed with status N`, exits 1, no later step runs; success
  deletes the marker and logs `apply complete`; the resumed header appears
  when the marker predates the faked boot time.
- `test/start-apply.bats`: validate failure exits 2 before copy or import;
  the four states map to `clear`, `enable`, `restart`, and no action;
  `svccfg import` runs on every call; the marker and `/var/homicron` are
  created.
- `test/watch-apply.bats`: prints lines after N only; exits 0 on `online`,
  1 on `maintenance`, 3 otherwise with the state; keeps looping while
  `offline*`.
- `test/homicron.bats`: the hosts-file, keys, `host.env`, unreachable, and
  keepalive tests stay. The step-order and reboot tests become: ships then
  starts then watches; a running service attaches without rsync and starts
  the watch after the last run header; 255 after a `rebooting for` line
  waits for a new boot time and reconnects with the line count; 255 with
  no such line is unreachable; `maintenance` exits with the step's status
  and names the step; the timeout message; `apply complete`.
- `test/step-voxel-images.bats`: both present skips; one present builds
  only the other; the create order; a failed first build does not run the
  second.
- `test/run-step.bats` is removed with `run-step.sh`.
- `test/lint.sh` covers the new scripts; the manifest is checked by
  `xmllint --noout` like the first-boot manifest.
