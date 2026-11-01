# Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 23 review findings that can hurt the first physical install or the first `apply`. Each fix lands with its test before the qemu rehearsal and the install on 2026-11-02.

**Architecture:** The repository keeps its three stages. DNS moves from the first-boot script into a dhcpagent event hook that the installer seeds. The runner gets one ssh option array, boot-time reboot detection, and hosts file validation. Host steps 10, 30, 60, and 70 get direct end-state signals in place of inferred ones. The qemu scripts and the Pages workflow get the two fixes that protect today's rehearsal.

**Tech Stack:** bash 5, bats-core, shellcheck, GitHub Actions, qemu-system-x86_64 with KVM. Illumos tools on the target: `ipadm`, `dhcpinfo`, `dhcpagent`, `kstat`, `beadm`, `pkg`, `svcadm`.

**Spec:** `docs/superpowers/specs/2026-11-01-review-fixes-design.md`

## Global Constraints

- Every script starts with `#!/bin/bash`. Target scripts must run on Helios `/bin/bash`. Laptop scripts must run on macOS `/bin/bash` 3.2 and on Linux.
- Exit codes: 0 success, 2 usage or configuration error, 10 (steps only) reboot required, 1 any other failure. The first-boot method and the event hook always exit 0.
- Every path a target script reads or writes has an environment override so tests run on a laptop. New overrides in this plan: `HOMICRON_ROOT_HOME=/root` (step 10), `HOMICRON_EVENTHOOK=/etc/dhcp/eventhook` (first boot), `HOMICRON_RESOLV_CONF=/etc/resolv.conf` (event hook and installer).
- Tests fake target commands by prepending `$FAKE_BIN` to `PATH` with `make_fake` from `test/helpers/fakes.bash`. No test runs a real `ssh`, `rsync`, `curl`, `pkg`, `beadm`, `zfs`, or `qemu`.
- `test/lint.sh` and `test/run-tests.sh` pass at every commit. Run both before each commit step.
- One commit per task. The message names the component and the fix.
- Prose in README and hosts/README follows the writing rules already in those files: short sentences, no contractions, no semicolons.

## Review Focus

1. A value set in the environment, not the file, can hold a space or a quote. `write_resolved_env` ships it and `run-step.sh` sources it on the box. The runner must refuse it with exit 2 before any rsync. Pinned in Task 4.
2. `kstat` can fail or be absent. The runner must still reboot, wait for ssh, and rerun the step instead of dying. Pinned in Task 5.
3. When `VOXEL_REF` names nothing, `resolve_ref` fails. Step 60 must exit nonzero without running `git checkout` or `cargo build`. Pinned in Task 8.
4. A keys file that holds only comment lines has no key. Step 10 must refuse it like an empty file. Pinned in Task 10.
5. The event hook can be missing on a box installed from an older site. First boot must log that and still exit 0 and disable itself. Pinned in Task 13.

---

### Task 1: Pages deploy concurrency group

**Files:**
- Modify: `.github/workflows/pages.yml:31-43`

**Interfaces:**
- Produces: nothing other tasks use.

- [ ] **Step 1: Add the group to the deploy job**

Under `deploy:`, after `needs: build`, add:

```yaml
    concurrency:
      group: pages
      cancel-in-progress: false
```

Put it on the `deploy` job only. The workflow also runs `lint` on pull requests, and a workflow-level group serializes those too.

- [ ] **Step 2: Make sure that the file still parses**

Run: `python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/pages.yml"))'`
Expected: no output, exit 0. If PyYAML is absent, run `ruby -ryaml -e 'YAML.load_file(".github/workflows/pages.yml")'` instead.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/pages.yml
git commit -m "Pages: concurrency group on the deploy job so overlapping pushes queue"
```

---

### Task 2: qemu: safe ISO download and an uncabled second NIC

**Files:**
- Modify: `test/qemu.sh:81-85` (download), `test/qemu.sh:57-74` (command), header comment
- Test: `test/qemu.bats`

**Interfaces:**
- Produces: environment variable `HOMICRON_VM_NIC2=yes`.

- [ ] **Step 1: Write the failing tests**

Add `load helpers/fakes` at the top of `test/qemu.bats` and these tests:

```bash
@test "HOMICRON_VM_NIC2=yes adds a second virtio nic with no peer" {
  HOMICRON_VM_DIR=/tmp/x HOMICRON_VM_NIC2=yes run "$SCRIPT" --dry-run boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"-netdev socket,id=n1,listen=:0"* ]]
  [[ "$output" == *"-device virtio-net-pci,netdev=n1"* ]]
  HOMICRON_VM_DIR=/tmp/x run "$SCRIPT" --dry-run boot
  [[ "$output" != *"netdev=n1"* ]]
}

@test "a failed iso download leaves no iso behind" {
  fakes_setup
  make_fake curl 18
  dir="$BATS_TEST_TMPDIR/vm"
  HOMICRON_VM_DIR="$dir" run "$SCRIPT" install
  [ "$status" -eq 18 ]
  [ ! -e "$dir/helios-install-ttya.iso" ]
  assert_called "^curl -fL -o $dir/helios-install-ttya.iso.part "
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/qemu.bats`
Expected: the two new tests FAIL. The first because the output has no `netdev=n1`. The second because the fake curl is not called with `.part`.

- [ ] **Step 3: Implement**

In `test/qemu.sh`:
- Add `nic2=${HOMICRON_VM_NIC2:-}` with the other variables and document it in the header comment: `HOMICRON_VM_NIC2 (unset) yes adds a second NIC with no peer, like an uncabled port`.
- If `$nic2 == yes`, append `-netdev "socket,id=n1,listen=:0"` and `-device "virtio-net-pci,netdev=n1"` after the `disk2` block in the command array.
- Replace the download with `curl -fL -o "$iso.part" "$iso_url"` followed by `mv "$iso.part" "$iso"`. If curl fails, errexit stops the script before the `mv`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/qemu.bats && test/lint.sh`
Expected: all PASS, lint exit 0.

- [ ] **Step 5: Commit**

```bash
git add test/qemu.sh test/qemu.bats
git commit -m "qemu harness: download the ISO to a .part file, optional uncabled second NIC"
```

---

### Task 3: Runner: one ssh option array, honest rsync failures

**Files:**
- Modify: `bin/homicron:33-69` (load_host, remote, sync_to_box), `bin/homicron:82-91` (wait_for_ssh probe), `bin/homicron:132` (reboot), `bin/homicron:154` (ssh subcommand)
- Test: `test/homicron.bats`

**Interfaces:**
- Produces: global array `ssh_opts` set by `load_host`, holding `-p "$HOMICRON_PORT" -o ServerAliveInterval=5 -o ServerAliveCountMax=3`. `remote CMD...` runs `ssh "${ssh_opts[@]}" "root@$HOMICRON_ADDR" CMD...`. Task 5 uses `remote`.

- [ ] **Step 1: Update the anchored assertions and write the failing tests**

In `test/homicron.bats`, change the three anchored lines:

```bash
# line 38-39
assert_called '^ssh -p 2222 .*root@box.local /opt/homicron/run-step.sh 10-a.sh$'
assert_called '^ssh -p 2222 .*root@box.local /opt/homicron/run-step.sh 20-b.sh$'
# line 77
assert_called '^ssh -p 2222 .*vmuser@box.local$'
```

Add:

```bash
@test "every ssh and the rsync transport carry keepalives" {
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^ssh -p 2222 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@box.local /opt/homicron/run-step.sh 10-a.sh$'
  assert_called '^rsync .* -e ssh -p 2222 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 .*host.env$'
}

@test "an rsync failure that is not 255 is reported as rsync, not as unreachable" {
  make_fake rsync 127
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"rsync failed with status 127"* ]]
  [[ "$output" != *"cannot reach"* ]]
  refute_called '^ssh'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/homicron.bats`
Expected: the two new tests FAIL. The other tests still PASS.

- [ ] **Step 3: Implement**

In `bin/homicron`:
- Declare `ssh_opts=()` near `remote_dir`. At the end of `load_host`, after the `HOMICRON_PORT` default, set `ssh_opts=(-p "$HOMICRON_PORT" -o ServerAliveInterval=5 -o ServerAliveCountMax=3)`.
- `remote` becomes `ssh "${ssh_opts[@]}" "root@$HOMICRON_ADDR" "$@"`.
- `sync_to_box` uses `-e "ssh ${ssh_opts[*]}"`, captures the status with `|| status=$?`, and ends with: status 0 returns, status 255 dies `cannot reach $HOMICRON_ADDR` 1, anything else dies `rsync failed with status $status` 1.
- The probe in `wait_for_ssh` becomes `ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "root@$HOMICRON_ADDR" true`.
- The reboot at line 132 becomes `remote reboot || true`. Delete the keepalive comment above it, and move its point into a one-line comment on `ssh_opts`.
- The ssh subcommand becomes `exec ssh "${ssh_opts[@]}" "$HOMICRON_USER@$HOMICRON_ADDR"`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/homicron.bats && test/lint.sh`
Expected: all PASS, lint exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron test/homicron.bats
git commit -m "Runner: one ssh option array with keepalives, rsync failures named as such"
```

---

### Task 4: Runner: validate hosts file lines and shipped values

**Files:**
- Modify: `bin/homicron:33-57` (load_host), `bin/homicron:73-80` (write_resolved_env)
- Modify: `hosts/README.md:3-6`
- Test: `test/homicron.bats`

**Interfaces:**
- Produces: `valid_value VALUE` returns 0 for a VALUE with none of these characters: whitespace, `'`, `"`, `#`, `\`, backtick, `$`. `load_host` exits 2 on a bad line with the message `hosts/<name>.env line N: expected KEY=VALUE with no spaces, quotes, or comments`. If a resolved value fails `valid_value`, `write_resolved_env` exits 2 with `VAR has characters the runner cannot ship`.

- [ ] **Step 1: Write the failing tests**

```bash
@test "malformed hosts lines exit 2 with the line number before rsync" {
  for bad in '  HOMICRON_UID=501' 'export HOMICRON_ADDR=box.lan' 'HOMICRON_ADDR' 'HOMICRON_ADDR=box.lan # lab' 'HOMICRON_PORT="2222"' $'HOMICRON_PORT=2222\r'; do
    printf 'HOMICRON_USER=vmuser\nHOMICRON_UID=501\n%s\n' "$bad" > "$REPO/hosts/bad.env"
    run "$REPO/bin/homicron" apply bad
    [ "$status" -eq 2 ]
    [[ "$output" == *"bad.env line 3"* ]]
  done
  refute_called '^rsync'
}

@test "a value from the environment with shell characters exits 2 before rsync" {
  HOMICRON_ADDR='box.lan # lab' run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOMICRON_ADDR"* ]]
  refute_called '^rsync'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/homicron.bats`
Expected: the two new tests FAIL (status 1 or 0, not 2).

- [ ] **Step 3: Implement**

In `bin/homicron`:
- Add `valid_value` with the regex held in a single-quoted variable: `local re='^[^[:space:]'\''"#\\`$]*$'` then `[[ $1 =~ $re ]]`. `[:space:]` covers the carriage return.
- In `load_host`, count lines in `n`. For each non-comment line, require `[[ $line =~ ^[A-Z][A-Z0-9_]*= ]]` and `valid_value "${line#*=}"`, else `die "hosts/$name.env line $n: expected KEY=VALUE with no spaces, quotes, or comments" 2`. Do this before `export`.
- In `write_resolved_env`, before printing each variable, `valid_value "${!var}" || die "$var has characters the runner cannot ship" 2`.
- In `hosts/README.md`, after the sentence "the runner reads the value literally", add: "A line that breaks the rule stops the runner with exit 2 and the line number. Values set in the environment follow the same rule."

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/homicron.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron hosts/README.md test/homicron.bats
git commit -m "Runner: validate hosts file lines and shipped values, exit 2 with the line"
```

---

### Task 5: Runner: detect the reboot by kernel boot time

**Files:**
- Modify: `bin/homicron:82-91` (wait_for_ssh), `bin/homicron:127-136` (reboot branch)
- Test: `test/homicron.bats`

**Interfaces:**
- Consumes: `remote` from Task 3.
- Produces: `boot_time` prints the second field of `kstat -p unix:0:system_misc:boot_time` run over `remote`, or fails. `reboot_box` sends `reboot` and polls until `boot_time` works and differs from the value read before. If the value is unchanged, it resends `reboot`. After `reboot_timeout` seconds it dies. It replaces `wait_for_ssh`.

- [ ] **Step 1: Update the existing reboot test and write the failing tests**

Replace the ssh fake in the test at `test/homicron.bats:44-57` so `kstat` answers with a boot time that changes once `reboot` was sent:

```bash
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) n=$(grep -c 'reboot$' "$FAKE_LOG"); printf 'unix:0:system_misc:boot_time\t%s\n' "$((1000 + n))"; exit 0 ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
```

Add:

```bash
@test "an unchanged boot time means the reboot was lost; it is sent again" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) n=$(grep -c 'kstat' "$FAKE_LOG"); if (( n <= 2 )); then t=1000; else t=1001; fi; printf 'unix:0:system_misc:boot_time\t%s\n' "$t"; exit 0 ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [ "$(fake_calls | grep -c 'reboot$')" -eq 2 ]
  [[ "$output" == *"has not rebooted yet"* ]]
  [ "$(fake_calls | grep -c '10-a.sh$')" -eq 2 ]
}

@test "a failing kstat still reboots, waits for ssh, and reruns the step" {
  cat > "$FAKE_BIN/ssh.script" <<'EOS'
case "$*" in
  *kstat*) exit 1 ;;
  *10-a.sh) n=$(grep -c '10-a.sh$' "$FAKE_LOG"); if [[ $n -eq 1 ]]; then exit 10; else exit 0; fi ;;
  *) exit 0 ;;
esac
EOS
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called 'root@box.local reboot$'
  [ "$(fake_calls | grep -c '10-a.sh$')" -eq 2 ]
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/homicron.bats`
Expected: the lost-reboot test FAILS with one `reboot` and no "has not rebooted yet". The other two PASS already, because the old poll accepts the first working ssh.

- [ ] **Step 3: Implement**

In `bin/homicron`:
- `boot_time() { remote 'kstat -p unix:0:system_misc:boot_time' | awk '{ print $2 }'; }`. With pipefail, a failed ssh makes the function fail.
- `reboot_box()`: read `before=$(boot_time)` with `|| before=` so a failing kstat gives an empty value. Send `remote reboot || true`. Loop: die with `cannot reach $HOMICRON_ADDR after reboot (${reboot_timeout}s)` once `SECONDS` passes the deadline, `sleep "$poll"`, then `now=$(boot_time 2>/dev/null) || continue`. When `now` is non-empty and differs from `before`, return 0. Otherwise print `box has not rebooted yet; sending reboot again`, send `remote reboot || true`, and loop. An empty `before` with any non-empty `now` counts as changed, so a box without `kstat` falls back to "ssh works again".
- In `apply`, the exit 10 branch becomes: print the request, call `reboot_box`, rerun the step. Delete `wait_for_ssh` and the `sleep "$(( poll * 4 ))"`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/homicron.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron test/homicron.bats
git commit -m "Runner: detect the reboot by kernel boot time, resend a lost reboot"
```

---

### Task 6: Runner: closing message prints the binary path

**Files:**
- Modify: `bin/homicron:143-144`, `README.md:47` (step 7)
- Test: `test/homicron.bats:41`

**Interfaces:**
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing assertion**

In the test "runs steps in order over ssh with the port", add after the `apply complete` assertion:

```bash
  [[ "${lines[-1]}" == '  pfexec ~/src/voxel/target/release/voxel image create && pfexec ~/src/voxel/target/release/voxel image create-frr proto' ]]
```

- [ ] **Step 2: Run the test to make sure that it fails**

Run: `bats test/homicron.bats -f "runs steps in order"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Change line 144 of `bin/homicron` to print that line. In `README.md` step 7, replace the command with the same two `pfexec` commands joined by `&&`, and add one sentence: "The binary is not on the PATH, so the command names its path."

- [ ] **Step 4: Run the tests**

Run: `bats test/homicron.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron README.md test/homicron.bats
git commit -m "Runner: closing message names the voxel binary by path"
```

---

### Task 7: Step 70: compare strings without TOML quotes

**Files:**
- Modify: `host/70-voxel-conf.sh:22-24`
- Test: `test/step-voxel-conf.bats`

**Interfaces:**
- Produces: nothing other tasks use.

- [ ] **Step 1: Make the fake voxel quote strings and write the failing test**

In `test/step-voxel-conf.bats` setup, change the `config get` branch of the fake so a non-numeric value prints inside double quotes, as upstream does:

```bash
  "config get") awk -v k="\$3" '\$1 == k { if (\$2 ~ /^[0-9]+\$/) print \$2; else print "\\"" \$2 "\\"" }' "$CONF" ;;
```

Add:

```bash
@test "a string value already set converges although config get quotes it" {
  printf 'topology.sleds 4\ntopology.sled_memory_gb 8\nfalcon.dataset fastpool/falcon\n' > "$CONF"
  FALCON_DATASET=fastpool/falcon run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^voxel config set'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/step-voxel-conf.bats`
Expected: the new test FAILS with status 1. The existing falcon.dataset test FAILS on `[ "$status" -eq 0 ]`.

- [ ] **Step 3: Implement**

`current` pipes the output through `sed -e 's/^"//' -e 's/"$//'`, keeping the trailing `|| true`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/step-voxel-conf.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add host/70-voxel-conf.sh test/step-voxel-conf.bats
git commit -m "voxel-conf step: strip TOML quotes from config get before comparing"
```

---

### Task 8: Step 60: one resolve_ref with --verify, detach at the commit

**Files:**
- Modify: `host/60-voxel.sh:27-60`
- Test: `test/step-voxel.bats`

**Interfaces:**
- Produces: `resolve_ref` prints one commit id for `$ref`, trying `origin/$ref^{commit}` then `$ref^{commit}` with `git rev-parse --verify -q`, or fails. It replaces `target_commit`.

- [ ] **Step 1: Write the failing tests**

Change the default git fake in setup so `rev-parse` without `--verify` prints the failed name first, as real git does:

```bash
  printf 'case "$1" in rev-parse) if [[ $* == *--verify* ]]; then echo abc123; else echo "origin/${*: -1}"; echo abc123; fi ;; clone) mkdir -p "${*: -1}/.git" ;; esac; exit 0\n' > "$FAKE_BIN/git.script"
```

Add to the rebuild test, after the cargo assertion:

```bash
  grep -q 'git checkout --detach abc123' "$FAKE_LOG.su"
  [ "$(grep -c 'git fetch' "$FAKE_LOG.su")" -eq 2 ]
```

Add to the clone test:

```bash
  [ "$(grep -c 'git fetch' "$FAKE_LOG.su")" -eq 1 ]
```

Add:

```bash
@test "a tag ref converges on the first run" {
  make_checkout
  echo abc123 > "$SRC/target/.homicron-built"
  VOXEL_REF=v0.9 run "$STEP"
  [ "$status" -eq 0 ]
  ! grep -q 'cargo build' "$FAKE_LOG.su"
}

@test "a ref that resolves to nothing fails before checkout or build" {
  make_checkout
  printf 'case "$1" in rev-parse) [[ $* == *--verify* ]] && exit 1; echo abc123 ;; esac; exit 0\n' > "$FAKE_BIN/git.script"
  run "$STEP"
  [ "$status" -ne 0 ]
  ! grep -q 'git checkout' "$FAKE_LOG.su"
  ! grep -q 'cargo build' "$FAKE_LOG.su"
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/step-voxel.bats`
Expected: "does nothing" and "a tag ref converges" FAIL (two-line target), the fetch counts FAIL (3, not 2), the nothing-resolves test FAILS.

- [ ] **Step 3: Implement**

In `host/60-voxel.sh`:
- Replace `target_commit` with `resolve_ref() { as_user "cd $src && { git rev-parse --verify -q 'origin/$ref^{commit}' || git rev-parse --verify -q '$ref^{commit}'; }"; }`.
- `at_ref` compares `head_commit` with `resolve_ref`.
- In `apply`, after the clone block: declare `local commit` on its own line, then `commit=$(resolve_ref)`, so a failed resolve exits the step under errexit. Then `log "checking out $commit ($ref)"` and `as_user "cd $src && git checkout --detach $commit"`. Delete the `fetch` call and the two-branch checkout.
- Move `marker=` up beside `src` and `repo`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/step-voxel.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add host/60-voxel.sh test/step-voxel.bats
git commit -m "voxel step: resolve the ref once with --verify, check out the commit"
```

---

### Task 9: Step 30: detect a pending reboot from beadm flags

**Files:**
- Modify: `host/30-pkg.sh:29-83`
- Test: `test/step-pkg.bats`

**Interfaces:**
- Produces: `reboot_pending`. If `beadm list -H` has a row whose third `;` field contains `R` and not `N`, it succeeds.

- [ ] **Step 1: Rewrite the beadm fakes and write the failing tests**

`beadm list -H` prints `name;uuid;active;mountpoint;space;policy;created`. In setup, use `make_fake beadm 0 'helios;;NR;/;1G;static;2026-10-31'`. Define a helper in the test file:

```bash
# beadm answers ROWS_BEFORE until a fake log line matches TRIGGER, then ROWS_AFTER.
beadm_flips_on() {
  printf 'if grep -q "%s" "$FAKE_LOG"; then printf "%%b" "%s"; else printf "%%b" "%s"; fi\n' "$1" "$3" "$2" > "$FAKE_BIN/beadm.script"
}
```

Rewrite the two existing exit-10 tests to use it with `'helios;;NR;/;1G;static;x\n'` before and `'helios;;N;/;1G;static;x\nhelios-1;;R;-;1G;static;x\n'` after, triggered on `^pkg update -v` and `^pkg install -v developer`. Add:

```bash
@test "a backup boot environment that is not activated does not request a reboot" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && { grep -q "^pkg install -v developer" "$FAKE_LOG" && exit 0 || exit 1; }; exit 0\n' > "$FAKE_BIN/pkg.script"
  beadm_flips_on '^pkg update -v' 'helios;;NR;/;1G;static;x\n' 'helios;;NR;/;1G;static;x\nhelios-backup-1;;-;-;1G;static;x\n'
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called "^pkg install -v $PKGS$"
}

@test "a boot environment activated by the pkg self-update requests a reboot" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && exit 1; exit 0\n' > "$FAKE_BIN/pkg.script"
  beadm_flips_on '^pkg install -v pkg:/package/pkg' 'helios;;NR;/;1G;static;x\n' 'helios;;N;/;1G;static;x\nhelios-1;;R;-;1G;static;x\n'
  run "$STEP"
  [ "$status" -eq 10 ]
  refute_called '^pkg update -v$'
}

@test "a boot environment left activated by an earlier run requests a reboot at entry" {
  printf '[[ $1 == update && $2 == -n ]] && exit 0; [[ $1 == list ]] && exit 1; exit 0\n' > "$FAKE_BIN/pkg.script"
  make_fake beadm 0 $'helios;;N;/;1G;static;x\nhelios-1;;R;-;1G;static;x'
  run "$STEP"
  [ "$status" -eq 10 ]
  refute_called '^pkg install'
  refute_called '^pkg update -v'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/step-pkg.bats`
Expected: the backup test FAILS with status 10, the self-update and entry tests FAIL with status 1 or 0.

- [ ] **Step 3: Implement**

In `host/30-pkg.sh`:
- Replace `boot_environments` with `reboot_pending() { beadm list -H 2>/dev/null | awk -F';' '$3 ~ /R/ && $3 !~ /N/ { found = 1 } END { exit !found }'; }`.
- Add `request_reboot_if_pending MESSAGE`. If `reboot_pending` succeeds, it logs MESSAGE and exits 10.
- In `apply`, call it four times. At entry: `a boot environment is already activated for the next boot; reboot required`. After the self-update block: `pkg(7) update created a new boot environment; reboot required`. After the `pkg update` case: `update created a new boot environment; reboot required`. After the package install: `package install created a new boot environment; reboot required`. Delete `before`, `after`, and the two name-set compares. Update the header comment.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/step-pkg.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add host/30-pkg.sh test/step-pkg.bats
git commit -m "pkg step: request a reboot from the beadm active-on-reboot flag"
```

---

### Task 10: Step 10: keys guard, root keys, no recursive chown

**Files:**
- Modify: `host/10-user.sh:14-22` (paths), `host/10-user.sh:43-53` (predicates), `host/10-user.sh:75-82` (keys block), before `step_main`
- Test: `test/step-user.bats`

**Interfaces:**
- Produces: `keys_present`. If `$keys_src` has a line that does not start with `#` or whitespace, it succeeds. `root_keys_match` compares `$keys_src` with `$root_home/.ssh/authorized_keys`, where `root_home=${HOMICRON_ROOT_HOME:-/root}`.

- [ ] **Step 1: Write the failing tests**

In setup add `export HOMICRON_ROOT_HOME="$BATS_TEST_TMPDIR/root"` and `mkdir -p "$HOMICRON_ROOT_HOME"`. In the first test, the one that expects no change, also place the keys at `$HOMICRON_ROOT_HOME/.ssh/authorized_keys` before the run. Add:

```bash
@test "refuses an empty or comment-only keys file before any change" {
  make_fake getent 2
  for content in '' $'# nothing here\n\n'; do
    printf '%s' "$content" > "$HOMICRON_DIR/authorized_keys"
    run "$STEP"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no key"* ]]
  done
  refute_called '^useradd'
  refute_called '^zfs create'
  [ ! -e "$HOMICRON_HOME/vmuser/.ssh/authorized_keys" ]
}

@test "converges root's authorized_keys as well as the user's" {
  make_fake getent 2
  run "$STEP"
  cmp "$HOMICRON_ROOT_HOME/.ssh/authorized_keys" "$HOMICRON_DIR/authorized_keys"
  assert_called "^chmod 0600 .*/root/.ssh/authorized_keys$"
}

@test "chown is not recursive" {
  make_fake getent 2
  run "$STEP"
  refute_called '^chown -R'
  assert_called "^chown vmuser:staff $HOMICRON_HOME/vmuser $HOMICRON_HOME/vmuser/.ssh $HOMICRON_HOME/vmuser/.ssh/authorized_keys$"
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/step-user.bats`
Expected: the three new tests FAIL.

- [ ] **Step 3: Implement**

In `host/10-user.sh`:
- Add `root_home=${HOMICRON_ROOT_HOME:-/root}` with the other paths.
- `keys_present() { grep -Eq '^[^#[:space:]]' "$keys_src"; }` and `root_keys_match` by analogy with `keys_match`.
- `check` adds `root_keys_match`.
- In `apply`, a block for root: if `! root_keys_match`, then log, `mkdir -p "$root_home/.ssh"`, `cp`, `chmod 0700 "$root_home/.ssh"`, `chmod 0600 "$root_home/.ssh/authorized_keys"`.
- Replace `chown -R "$user:staff" "$home"` with `chown "$user:staff" "$home" "$home/.ssh" "$home/.ssh/authorized_keys"`.
- Before `step_main`: `keys_present || { log "$keys_src has no key; refusing to change $user or root"; exit 1; }`.
- Update the header comment: root's keys are converged too.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/step-user.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add host/10-user.sh test/step-user.bats
git commit -m "user step: refuse an empty keys file, converge root's keys, chown three paths"
```

---

### Task 11: Installer: keys guard rule and checksum mismatch hint

**Files:**
- Modify: `install/install.sh:86-95`
- Test: `test/install.bats`

**Interfaces:**
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing tests**

```bash
@test "accepts a keys file whose only key is a hardware-backed sk- key" {
  printf 'sk-ssh-ed25519@openssh.com AAAA test\n' > "$BATS_TEST_TMPDIR/site/keys/authorized_keys"
  fake_site_resum "$BATS_TEST_TMPDIR/site"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  assert_called '^install-helios'
}

@test "a comment-only keys file still counts as no key" {
  printf '# keys go here\n' > "$BATS_TEST_TMPDIR/site/keys/authorized_keys"
  fake_site_resum "$BATS_TEST_TMPDIR/site"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  refute_called '^install-helios'
}
```

In "exits 1 before install on checksum mismatch" add `[[ "$output" == *"retry"* ]]`.

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/install.bats`
Expected: the sk- test and the mismatch assertion FAIL.

- [ ] **Step 3: Implement**

Change the guard to `grep -Eq '^[^#[:space:]]'`. Change the mismatch call to `fail "checksum mismatch for $f (the site cache can serve an old file for ten minutes after a deploy; retry then)"`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/install.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add install/install.sh test/install.bats
git commit -m "Installer: accept any key line, name the site cache on checksum mismatch"
```

---

### Task 12: The dhcpagent event hook

**Files:**
- Create: `firstboot/dhcp-eventhook`
- Modify: `test/lint.sh:9-17` (add the file to the list)
- Test: `test/eventhook.bats` (new)

**Interfaces:**
- Produces: `firstboot/dhcp-eventhook INTERFACE EVENT`. It acts on `BOUND`, `EXTEND`, and `INFORM` only. If `dhcpinfo -i INTERFACE DNSserv` prints no servers, it does nothing. It writes `$HOMICRON_RESOLV_CONF` (default `/etc/resolv.conf`) through `<file>.tmp.$$` and `mv`. The file holds an optional `domain` line from `DNSdmain` and one `nameserver` line per server. It then runs `svcadm refresh network/dns/client` and appends `homicron-dhcp-eventhook: wrote <file> from <interface>` to `$HOMICRON_MSGLOG` (default `/dev/msglog`). It always exits 0. Task 13 calls it. Task 14 publishes and seeds it.

- [ ] **Step 1: Write the failing tests**

```bash
load helpers/fakes

HOOK="$BATS_TEST_DIRNAME/../firstboot/dhcp-eventhook"

setup() {
  fakes_setup
  export HOMICRON_RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf" HOMICRON_MSGLOG="$BATS_TEST_TMPDIR/msglog"
  make_fake svcadm
  make_fake dhcpinfo
  printf 'case "$*" in *DNSserv) printf "10.0.2.3 10.0.2.4\\n" ;; *DNSdmain) echo lan ;; esac; exit 0\n' > "$FAKE_BIN/dhcpinfo.script"
}

@test "BOUND writes domain and nameservers and refreshes dns/client" {
  run "$HOOK" rge0 BOUND
  [ "$status" -eq 0 ]
  [ "$(cat "$HOMICRON_RESOLV_CONF")" = $'domain lan\nnameserver 10.0.2.3\nnameserver 10.0.2.4' ]
  assert_called '^svcadm refresh network/dns/client$'
  grep -q 'wrote .*resolv.conf from rge0' "$HOMICRON_MSGLOG"
  [ ! -e "$HOMICRON_RESOLV_CONF.tmp."* ]
}

@test "EXTEND and INFORM write, every other event leaves the file alone" {
  for ev in EXTEND INFORM; do rm -f "$HOMICRON_RESOLV_CONF"; run "$HOOK" rge0 "$ev"; [ -s "$HOMICRON_RESOLV_CONF" ]; done
  printf 'nameserver 9.9.9.9\n' > "$HOMICRON_RESOLV_CONF"
  for ev in EXPIRE DROP RELEASE; do
    run "$HOOK" rge0 "$ev"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOMICRON_RESOLV_CONF")" = "nameserver 9.9.9.9" ]
  done
  [ "$(fake_calls | grep -c '^dhcpinfo')" -eq 4 ]
}

@test "a lease without DNS servers changes nothing and exits 0" {
  make_fake dhcpinfo 1
  printf 'nameserver 9.9.9.9\n' > "$HOMICRON_RESOLV_CONF"
  run "$HOOK" rge0 BOUND
  [ "$status" -eq 0 ]
  [ "$(cat "$HOMICRON_RESOLV_CONF")" = "nameserver 9.9.9.9" ]
  refute_called '^svcadm'
}

@test "no domain in the lease gives nameserver lines only" {
  printf 'case "$*" in *DNSserv) echo 10.0.2.3 ;; *) exit 1 ;; esac; exit 0\n' > "$FAKE_BIN/dhcpinfo.script"
  run "$HOOK" rge0 BOUND
  [ "$(cat "$HOMICRON_RESOLV_CONF")" = "nameserver 10.0.2.3" ]
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/eventhook.bats`
Expected: all FAIL, the hook does not exist.

- [ ] **Step 3: Implement `firstboot/dhcp-eventhook`**

Header comment: what dhcpagent passes, which events matter, that it must always exit 0, and that the installer seeds it to `/etc/dhcp/eventhook`. `set -o nounset` only. `PATH="$PATH:/sbin:/usr/sbin"` because dhcpagent's environment is minimal. The two overrides from Interfaces. The order: the case on the event, then the two `dhcpinfo` reads with `2>/dev/null`. Then the temp-file write and `mv`, the refresh with `|| true`, and the msglog line with `2>/dev/null`. `chmod 0755` the file in the repository.

- [ ] **Step 4: Add the hook to lint and run everything**

Add `firstboot/dhcp-eventhook` under `firstboot/homicron-firstboot` in the `files` array of `test/lint.sh`.

Run: `test/lint.sh && bats test/eventhook.bats`
Expected: lint exit 0, all PASS.

- [ ] **Step 5: Commit**

```bash
git add firstboot/dhcp-eventhook test/eventhook.bats test/lint.sh
git commit -m "First boot: dhcpagent event hook writes resolv.conf on every lease"
```

---

### Task 13: First boot: -w 0, IPv4-only poll, hook per link

**Files:**
- Modify: `firstboot/homicron-firstboot:39-97`
- Test: `test/firstboot.bats`

**Interfaces:**
- Consumes: the hook from Task 12 at `${HOMICRON_EVENTHOOK:-/etc/dhcp/eventhook}`.

- [ ] **Step 1: Rewrite the affected tests and write the failing ones**

In setup, replace the `dhcpinfo` fake and `HOMICRON_RESOLV_CONF` with `make_fake eventhook` and `export HOMICRON_EVENTHOOK="$FAKE_BIN/eventhook"`. Change the two `-w 10` assertions to `-w 0`. Delete the two resolv.conf tests, the write test and the leave-alone test. Add:

```bash
@test "the ? placeholder does not count as an address" {
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "?"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'no DHCP address after 1s' "$HOMICRON_MSGLOG"
  ! grep -q '  ?' "$HOMICRON_MSGLOG"
}

@test "runs the dhcp hook once per link after the poll" {
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "10.0.2.15/24"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called '^eventhook rge0 BOUND$'
  assert_called '^eventhook rge1 BOUND$'
  [ "$(fake_calls | grep -c '^eventhook')" -eq 2 ]
}

@test "a missing hook is logged and the method still exits 0 and disables itself" {
  export HOMICRON_EVENTHOOK="$BATS_TEST_TMPDIR/absent"
  printf '[[ $1 == show-addr ]] && [[ $* == *-o\\ addr* ]] && echo "10.0.2.15/24"; exit 0\n' > "$FAKE_BIN/ipadm.script"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'dhcp hook' "$HOMICRON_MSGLOG"
  assert_called '^svcadm disable site/homicron-firstboot$'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/firstboot.bats`
Expected: the `-w 0` assertions, the placeholder test, and the two hook tests FAIL.

- [ ] **Step 3: Implement**

In `firstboot/homicron-firstboot`:
- `eventhook=${HOMICRON_EVENTHOOK:-/etc/dhcp/eventhook}` with the other variables. Remove `resolv_conf`.
- `-w 10` becomes `-w 0`, with the comment: dhcpagent keeps trying in the background and the poll below picks the address up.
- The poll filter becomes `grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '^127\.'` with no `|| true`.
- Delete `write_resolv_conf` and its comment block. After the poll, before the console line, run `"$eventhook" "$link" BOUND || say "dhcp hook failed on $link"` for each link in `$links`. When the hook file is missing, bash prints "No such file" and the `say` line reads `dhcp hook failed on rge0`.
- The no-address message becomes `no DHCP address after ${dhcp_wait}s; sshd is enabled, and the lease brings the address and DNS when it arrives`.
- Update the header comment: DNS comes from the hook.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/firstboot.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add firstboot/homicron-firstboot test/firstboot.bats
git commit -m "First boot: -w 0, ignore the ? placeholder, run the dhcp hook per link"
```

---

### Task 14: Publish and seed the hook, seed resolv.conf

**Files:**
- Modify: `pages/build-site.sh:32-41`, `test/helpers/fake_site.bash:22-36`, `install/install.sh:75-79` (files), `install/install.sh:104-116` (seeding)
- Test: `test/site.bats`, `test/install.bats`

**Interfaces:**
- Consumes: `firstboot/dhcp-eventhook` from Task 12.
- Produces: the site publishes `firstboot/dhcp-eventhook` and `SHA256SUMS` lists it. The installer reads `${HOMICRON_RESOLV_CONF:-/etc/resolv.conf}`.

- [ ] **Step 1: Write the failing tests**

In `test/site.bats`, add `firstboot/dhcp-eventhook` to the layout loop and change the line count to 5. In `test/install.bats` setup, add:

```bash
  export HOMICRON_RESOLV_CONF="$BATS_TEST_TMPDIR/ramdisk-resolv.conf"
  printf 'nameserver 10.0.2.3\n' > "$HOMICRON_RESOLV_CONF"
```

In the happy path test add:

```bash
  [ -x "$HOMICRON_ALTROOT/etc/dhcp/eventhook" ]
  [ "$(file_mode "$HOMICRON_ALTROOT/etc/dhcp/eventhook")" = 755 ]
  cmp "$HOMICRON_ALTROOT/etc/dhcp/eventhook" "$BATS_TEST_DIRNAME/../firstboot/dhcp-eventhook"
  [ "$(cat "$HOMICRON_ALTROOT/etc/resolv.conf")" = "nameserver 10.0.2.3" ]
```

Add:

```bash
@test "a ramdisk resolv.conf without a nameserver is not copied" {
  : > "$HOMICRON_RESOLV_CONF"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  [ ! -e "$HOMICRON_ALTROOT/etc/resolv.conf" ]
}

@test "a tampered hook fails the checksum before install" {
  echo tampered >> "$BATS_TEST_TMPDIR/site/firstboot/dhcp-eventhook"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  refute_called '^install-helios'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/site.bats test/install.bats`
Expected: the layout, count, happy path, and tampered hook tests FAIL.

- [ ] **Step 3: Implement**

- `pages/build-site.sh`: copy with `cp "$root"/firstboot/* "$out/firstboot/"` and sum with `sum_tool install firstboot/* keys/authorized_keys > SHA256SUMS` inside the `cd "$out"` subshell.
- `test/helpers/fake_site.bash`: the same glob in `fake_site_setup` and `fake_site_resum`.
- `install/install.sh`: add `firstboot/dhcp-eventhook` to `files`. Add `ramdisk_resolv=${HOMICRON_RESOLV_CONF:-/etc/resolv.conf}` with the other defaults. In section 5, `mkdir -p "$altroot/etc/dhcp"`, copy the hook to `$altroot/etc/dhcp/eventhook`, `chmod 0755`. If `grep -q '^nameserver' "$ramdisk_resolv" 2>/dev/null` succeeds, copy it to `$altroot/etc/resolv.conf` and `chmod 0644`. Update the header comment and the `printf 'seeding ...'` list.

- [ ] **Step 4: Run every test and lint**

Run: `test/lint.sh && test/run-tests.sh`
Expected: lint exit 0, all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add pages/build-site.sh test/helpers/fake_site.bash install/install.sh test/site.bats test/install.bats
git commit -m "Installer and site: publish and seed the dhcp hook, seed resolv.conf from the ramdisk"
```

---

### Task 15: Documentation

**Files:**
- Modify: `README.md` (steps 5 and 7, stage table, rehearsal section, table of facts, findings list)
- Modify: `docs/superpowers/specs/2026-10-31-homicron-design.md` (one pointer line under Architecture)

**Interfaces:**
- Produces: nothing other tasks use.

- [ ] **Step 1: Edit README.md**

- Step 5: after "root accepts the keys", add "A dhcpagent hook writes `/etc/resolv.conf` from every lease."
- Stage table, `firstboot/` row: "DHCP on every physical NIC with a dhcpagent hook for DNS, enable sshd and mDNS, print the address, disable itself". `install/install.sh` row: add "the DNS hook" to the seeded list.
- Rehearsal section: after the `test/qemu.sh install` line, add a sentence: "Set `HOMICRON_VM_NIC2=yes` to add an uncabled second NIC like the IMB-A1002."
- Table of facts under the heading about the first install: two rows, VM column empty until the rehearsal. Row one: `ipadm create-addr -T dhcp -w 0` is accepted and dhcpagent keeps trying. Row two: dhcpagent runs `/etc/dhcp/eventhook` on BOUND.
- Findings list, the `dhcpagent` bullet: replace the sentence about first boot writing the file with "A dhcpagent event hook, seeded by the installer, writes it on every lease."
- Add a sentence to the install procedure after step 3: "If the install line stops with a checksum mismatch minutes after a push, the site cache is still serving an old file. Wait ten minutes and retry."

- [ ] **Step 2: Add the pointer in the original spec**

Under "## Architecture" in `docs/superpowers/specs/2026-10-31-homicron-design.md`, add one line: "Changes after the review of 2026-11-01 are in [2026-11-01-review-fixes-design.md](2026-11-01-review-fixes-design.md)."

- [ ] **Step 3: Make sure that nothing else changed**

Run: `test/lint.sh && test/run-tests.sh && git status --short`
Expected: lint and tests pass. Only the two documents are modified.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-10-31-homicron-design.md
git commit -m "README: dhcp hook, binary path, uncabled NIC rehearsal, cache retry note"
```

---

### Task 16: Rehearsal on the Arch Linux host

This task is manual. It follows the Rehearsal section of the spec. Record each result in the README table of facts and commit the table.

- [ ] **Step 1:** Push `main` and wait for the one queued Pages deploy to finish.
- [ ] **Step 2:** On the Arch host, pull, remove `test/vm/disk.qcow2`, start `test/serve.sh 8000`, and run `HOMICRON_VM_NIC2=yes test/qemu.sh install`.
- [ ] **Step 3:** Type the install line from the README rehearsal section, then `reboot`, quit qemu at the loader, and run `HOMICRON_VM_NIC2=yes test/qemu.sh boot`.
- [ ] **Step 4:** On the console, make sure that the address line shows one IPv4 address and no `?`. Make sure that `cat /etc/resolv.conf` has a nameserver line. Make sure that `/var/adm/messages` has the `homicron-dhcp-eventhook: wrote` line. Record the `-w 0` and hook rows.
- [ ] **Step 5:** From the laptop, `HOMICRON_ADDR=<arch-host> bin/homicron apply vm`. Make sure that the runner prints the reboot request and no "has not rebooted yet" line, or one that resolves.
- [ ] **Step 6:** Run `apply` again. Steps 60 and 70 must log "already in the desired state".
- [ ] **Step 7:** `bin/homicron ssh vm` and run the printed image command. Stop it once it starts building.
- [ ] **Step 8 (if time allows):** Rerun `apply` with a changed `VOXEL_REF`, and during the cargo build type `system_reset` in the qemu monitor. `apply` must exit with "cannot reach" within a minute.
- [ ] **Step 9:** Commit the README table.

```bash
git add README.md
git commit -m "README: rehearsal results for the review fixes"
```
