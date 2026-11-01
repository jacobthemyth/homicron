# Review fixes before the first install

Date: 2026-11-01

A full code review of `main` at commit bcc09bd found 45 issues, each one
reproduced or traced to source: 28 correctness bugs and 17 cleanups. The
first physical machine, the ASRock IMB-A1002, is installed on 2026-11-02. This document selects the issues that
can hurt that install or the first `apply`, designs the fixes, and records the
rest for later. The design in
[2026-10-31-homicron-design.md](2026-10-31-homicron-design.md) still holds.
This document changes only the details named below.

## Goals

- A fresh install on 2026-11-02 reaches a working `apply` without console
  repair.
- Every fix is covered by a bats test or by the qemu rehearsal, and the
  rehearsal happens before the physical install.
- The 22 deferred issues are listed here so the next round starts from the
  repository.

## Non-goals

- Fixing issues that need a hand-edited vfstab, a tag in `VOXEL_REF`, a
  cleared `FALCON_DATASET`, a second laptop, or a code change to trigger.
  They are listed under Deferred.
- Changing the typed install line.
- A `voxel` binary on the PATH. The closing message prints the path instead.

## Selected issues

| Area | Issue | Fix |
|---|---|---|
| first boot | the DHCP poll accepts the `?` placeholder that ipadm prints before a lease | match a dotted IPv4 address |
| first boot | a lease after the 60 s window never writes `/etc/resolv.conf` | a dhcpagent event hook writes it on every lease |
| first boot | `ipadm create-addr -w 10` adds 10 s per uncabled port | request with `-w 0` |
| first boot | three `\|\| true` guards with no errexit | removed with the function they guarded |
| installer | the installed root has no `/etc/resolv.conf` until first boot | if the ramdisk file holds a nameserver, copy it |
| installer | the keys guard rejects `sk-` keys and option-prefixed lines | accept any line that is not blank or a comment |
| installer | a checksum mismatch near a deploy reads like tampering | the message names the CDN cache and says to retry |
| runner | step ssh and rsync have no keepalives, a dead guest hangs `apply` | one `ssh_opts` array used by every ssh and rsync |
| runner | the ssh target is spelled five times | the same array |
| runner | a failed reboot ssh looks like a reboot | compare the kernel boot time before and after |
| runner | malformed hosts lines die with bash errors or pass silently | test each line, exit 2 with the line number |
| runner | `host.env` is sourced as shell on the box | follows from validation: every value is shell-safe |
| runner | every rsync failure says "cannot reach" | only exit 255 says it |
| runner | the closing `pfexec voxel image create` fails: not on PATH | print the binary path |
| step 10 | root's `authorized_keys` is frozen at install | converge it like the user's |
| step 10 | an empty keys file is installed unread | if no line is a key, refuse |
| step 10 | `chown -R` of the whole home on every key change | chown the three paths the step creates |
| step 30 | a boot environment from the pkg self-update never yields exit 10, a backup one does | test for a boot environment active on reboot but not now |
| step 60 | `git rev-parse` without `--verify` returns two lines for a tag or SHA | one `resolve_ref` function with `--verify -q` |
| step 60 | the checkout fallback is a drifted copy, apply fetches twice | detach at the resolved commit, drop the second fetch |
| step 70 | `voxel config get` prints strings with TOML quotes | strip one pair of quotes before comparing |
| qemu | an interrupted ISO download leaves a truncated file | download to a temporary name, rename on success |
| CI | two overlapping Pages deploys fail with HTTP 400 | a concurrency group on the deploy job |

## Design

### First boot and installer DNS

When a lease is bound, extended, expired, dropped, or released, dhcpagent
runs `/etc/dhcp/eventhook <interface> <event>`. A new file,
`firstboot/dhcp-eventhook`, is that hook. On `BOUND`, `EXTEND`, and `INFORM`
it reads `dhcpinfo -i <interface> DNSserv` and `DNSdmain`. It writes
`/etc/resolv.conf` through a temporary file and `mv`, then refreshes
`network/dns/client`. On every other event it exits 0 and changes nothing.
If the lease has no DNS servers, it does the same. The hook owns DNS for the
life of the machine. A lease that lands after first boot is handled, and so
is a lease that changes the servers.

The installer fetches the hook with the other first-boot files and makes
sure that it matches `SHA256SUMS`. It copies the hook to
`/a/etc/dhcp/eventhook` with mode 0755. The ramdisk runs as root, so the file
is owned by root. If the ramdisk's `/etc/resolv.conf` contains a `nameserver`
line, the installer also copies it to `/a/etc/resolv.conf`. The hook
overwrites that copy on the first lease, so the copy is only insurance.

The first-boot script becomes shorter. It requests DHCP with `-w 0` on every
physical link, so an uncabled port costs nothing. It polls up to 60 s for an
address that matches a dotted IPv4 pattern, so the `?` placeholder does not
end the poll. After the poll it runs the hook once per link with the `BOUND`
event, so the common case does not wait for the dhcpagent callback. It prints
the console line and disables itself. The function `write_resolv_conf` and
the `|| true` guards are removed. The no-address message says that the
lease, once it arrives, brings the address and DNS.

`pages/build-site.sh` copies and sums every file under `firstboot/` instead
of two named files. `test/helpers/fake_site.bash` does the same, so the new
file reaches the install tests without another list.

Facts the qemu rehearsal must make sure of: `ipadm create-addr -T dhcp -w 0` is
accepted and leaves dhcpagent running, and dhcpagent calls the hook on
`BOUND` under qemu user networking.

### The runner

`load_host` builds an array, `ssh_opts`, with `-p "$HOMICRON_PORT"`,
`-o ServerAliveInterval=5`, and `-o ServerAliveCountMax=3`. `remote` uses
it. `sync_to_box` passes it in the rsync `-e` transport. The `ssh`
subcommand uses it with the user. The reboot goes through `remote`. A guest
that dies behind a port forward then returns exit 255 within about 15 s.

`sync_to_box` says "cannot reach" only for exit 255. Any other rsync status
is reported as an rsync failure with its status.

Reboot detection uses the kernel boot time. Before `reboot`, the runner reads
`kstat -p unix:0:system_misc:boot_time` over ssh and keeps the value.
`wait_for_ssh` polls until ssh works and the boot time differs. When ssh
works and the boot time is unchanged, the reboot never reached the box. The
runner logs that, sends `reboot` again, and keeps polling. The 600 s timeout
still ends the wait. The 20 s sleep is removed.

`load_host` tests each line before it exports anything. A line that is not
blank or a comment must match an uppercase identifier, `=`, and a value. The
value must not contain whitespace, a quote, `#`, `\`, a backtick, `$`, or a
carriage return. A failing line prints the file, the line number, and the
rule, and exits 2. Because every value is shell-safe, the `host.env` that
`run-step.sh` sources on the box is safe too. `write_resolved_env` does not
change.

The closing message and README step 7 print
`pfexec ~/src/voxel/target/release/voxel image create && pfexec ~/src/voxel/target/release/voxel image create-frr proto`.

### Host steps

Step 70: `current` strips one pair of surrounding double quotes from the
output of `voxel config get` before the comparison. Integer keys print bare
and are not affected.

Step 60: a new function, `resolve_ref`, runs
`git rev-parse --verify -q 'origin/$ref^{commit}'` and then
`git rev-parse --verify -q '$ref^{commit}'`, and prints one commit id or
fails. `target_commit` calls it. `apply` checks out that commit id with
`git checkout --detach`. The second fetch in `apply` is removed: `check`
fetched already, and a fresh clone needs no fetch.

Step 30: a new function, `reboot_pending`, reads the active flags column of
`beadm list -H`. If any boot environment has `R` without `N`, the function
succeeds.
`apply` calls it at entry, after the pkg self-update, after `pkg update`,
and after the package install, and exits 10 at the first hit. The name-set
diff is removed.

Step 10: if the shipped keys file has no line that is not blank or a
comment, the step refuses with exit 1 before any change. The step converges
`/root/.ssh/authorized_keys` to the same file, with the root home overridable
by `HOMICRON_ROOT_HOME` for tests. The `chown -R` of the home becomes a
`chown` of the home, `.ssh`, and `authorized_keys`. The installer's keys
guard uses the same rule as the step.

### qemu, CI, and documentation

`test/qemu.sh` downloads the ISO to `<iso>.part`. If curl succeeds, it
renames the file. A new variable, `HOMICRON_VM_NIC2=yes`, adds a second
virtio NIC backed by a socket netdev with no peer. The guest then has one
cabled port and one uncabled port, like the IMB-A1002.

`.github/workflows/pages.yml` adds `concurrency` with group `pages` and
`cancel-in-progress: false` to the deploy job.

`install/install.sh` adds one line to the checksum mismatch message: the
site cache can hold an old file for ten minutes after a deploy, retry then.

README changes:

- The stage table and step 5 say DNS comes from the dhcpagent hook.
- Step 7 prints the binary path.
- The table of facts gains rows for `-w 0` and the hook.
- The rehearsal section documents `HOMICRON_VM_NIC2`.
- `hosts/README.md` states the line rule the runner enforces.

## Testing

Each fix lands in one commit with its tests, and `test/lint.sh` and
`test/run-tests.sh` pass at every commit.

- `test/firstboot.bats`: `-w 0` replaces `-w 10`. `?` output does not end
  the poll. The hook runs once per link after the poll.
- `test/eventhook.bats` (new): `BOUND` writes the file with a `domain` line.
  `EXPIRE` leaves it alone. A lease without servers leaves it alone.
- `test/install.bats`: the hook is fetched and seeded with mode 0755. When
  `resolv.conf` has a nameserver, it is copied. A keys file with only an
  `sk-` key installs.
- `test/site.bats`: `SHA256SUMS` lists every file under `firstboot/`.
- `test/homicron.bats`: the step ssh and the rsync transport carry the
  keepalive options. The reboot test gives the fake ssh two boot times, and
  the rerun happens only after the value changes. A second reboot test keeps
  the boot time fixed for one poll and asserts a second `reboot`. Six
  malformed line shapes exit 2 with the line number and no rsync. A
  non-255 rsync status is reported as an rsync failure.
- `test/step-voxel-conf.bats`: a quoted string from `config get` converges.
- `test/step-voxel.bats`: `--verify -q` is used. Checkout uses the resolved
  commit id. There is one fetch per apply.
- `test/step-pkg.bats`: beadm flags `N`, `NR`, `R`, and `-` give exit 10
  only for `R` without `N`, at entry and after the self-update.
- `test/step-user.bats`: an empty keys file is refused. Root's keys
  converge. chown is not recursive.
- `test/qemu.bats` (new or extended): a failing download leaves no ISO. The
  second NIC appears in the dry-run command.

## Rehearsal

Run this on the Arch Linux host before the physical install.

1. Push `main` and wait for the single queued Pages deploy.
2. Remove `test/vm/disk.qcow2` and run `HOMICRON_VM_NIC2=yes test/qemu.sh install`.
3. Type the install line against the served working tree, then `reboot`.
4. On the console, make sure that the address line shows one IPv4 address
   and no `?`, that `/etc/resolv.conf` has a `nameserver` line, and that
   msglog shows the hook ran.
5. Run `HOMICRON_ADDR=<arch-host> bin/homicron apply vm` from the laptop.
   Make sure that the runner logs the boot time change around the pkg
   reboot.
6. Run `apply` again. Steps 60 and 70 must report the desired state with no
   rebuild.
7. Run the printed image command on the box and make sure that it starts.
8. If time allows, reset the guest from the qemu monitor during the cargo
   build. `apply` must exit with "cannot reach" within a minute.

Record the results in the README table of facts.

## Deferred

These 22 findings are real, but none can affect the first install. Fix them
after the machine is up, with the VM as the rehearsal target.

| File | Line | Finding |
|---|---|---|
| host/10-user.sh | 72 | `usermod -K` and `-P` replace the whole privilege and profile lists |
| host/10-user.sh | 91 | the `#PATH=` branch appends without a `:` separator |
| host/10-user.sh | 31 | the dataset-existence probe is written three times |
| host/20-swap-dump.sh | 55 | a vfstab without a trailing newline gets a fused line |
| host/20-swap-dump.sh | 18 | `vfstab_line` hardcodes the path that `swap_dev` holds |
| host/30-pkg.sh | 43 | the post-reboot rerun repeats the self-update and update |
| host/30-pkg.sh | 48 | the pkg status rule is spelled three times |
| host/40-rust.sh | 19 | the rustup pipeline loses pipefail under `su` |
| host/60-voxel.sh | 36 | github.com alone unreachable makes step 60 fail |
| host/60-voxel.sh | 14 | the test-override prelude and voxel path are copied across steps |
| host/70-voxel-conf.sh | 17 | clearing `FALCON_DATASET` leaves the old value in voxel.toml |
| bin/homicron | 135 | a second exit 10 from step 30 is reported as a failure |
| bin/homicron | 76 | the host variable list is maintained in two places |
| bin/homicron | 106 | `step_failed` prints the whole append-only log |
| pages/build-site.sh | 31 | the OUTDIR guard still lets `rm -rf` wipe a repo subdirectory |
| test/lint.sh | 19 | a moved or deleted listed script leaves lint coverage silently |
| test/helpers/fakes.bash | 33 | `make_fake` interpolates STDOUT inside an unquoted heredoc |
| test/helpers/fake_site.bash | 26 | the sums step duplicates `build-site.sh` |
| test/step-user.bats | 34 | `status 0 or 1` assertions hide the post-apply verdict |
| test/step-voxel-conf.bats | 11 | the `su` fake prologue is duplicated in four tests |
| test/step-swap-dump.bats | 27 | the `dataset absent` zfs fake is copied twice |
| hosts/vm.env | 8 | restates code defaults as live pins (style only) |
