# Apply under SMF Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the step loop from `bin/homicron` to a transient SMF service on the box, so one apply runs at a time, survives a lost ssh, resumes after its own reboots, and builds the voxel images as a step.

**Architecture:** `host/apply.sh` is the start method of `svc:/site/homicron-apply:default` and runs the steps in order, logging to `/var/log/homicron/apply.log`, with a marker file `/var/homicron/apply-requested` that makes a boot resume an interrupted apply. `host/start-apply.sh` imports the manifest and starts a run; `host/watch-apply.sh` streams the log from a line offset until the service settles. `bin/homicron apply` ships `host/`, calls those two scripts over ssh, and prints the stream, reconnecting after the reboot the method announces.

**Tech Stack:** bash, SMF (`svccfg`, `svcadm`, `svcs`), bats with the PATH fakes in `test/helpers/fakes.bash`, shellcheck via `test/lint.sh`, xmllint.

**Spec:** `docs/superpowers/specs/2026-11-02-apply-under-smf-design.md`

## Global Constraints

- Every script: `#!/bin/bash`, a header comment saying what it is and who calls it, `set -o nounset -o pipefail` (and `errexit` unless the spec says otherwise), passes `test/lint.sh` (shellcheck).
- Paths on the box: `/opt/homicron` (`HOMICRON_DIR`), `/var/log/homicron` (`HOMICRON_LOG_DIR`), `/var/homicron` (`HOMICRON_STATE_DIR`), `/lib/svc/manifest/site` (`HOMICRON_MANIFEST_DIR`). Each has an environment override of that name so tests redirect it.
- Service FMRI: `site/homicron-apply`, instance `svc:/site/homicron-apply:default`. Never renamed.
- Protocol lines in `apply.log`, exact: `=== run <time>`, `=== run <time> (resumed after reboot)`, `==> <step>`, `rebooting for <step>`, `step <step> failed with status <N>`, `apply complete`.
- The runner's exit statuses: 0 converged, the step's own status on a failed step, 1 unreachable or runner error, 2 usage or hosts-file error.
- Tests fake every box command on PATH with `make_fake`; the test suite runs with `test/run-tests.sh` and must stay green after every task.
- Commit messages: imperative subject, a body that says why, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. A step that exits 10 again right after the reboot it asked for would reboot the box forever; `apply.sh` must fail that step instead. (Task 1)
2. `host.env` missing when the method runs at boot (box reinstalled, `/opt/homicron` gone) must log and exit 1, not die on `nounset`. (Task 1)
3. `watch-apply.sh` started before the method has written anything, or after an operator deleted `apply.log`, must treat a missing or short log as empty and keep going. (Task 3)
4. The runner attaching to a run must start from the current run's header, never from line 0 of a log that holds every past run. (Task 5)
5. A `watch-apply.sh` that blocks forever because the service never settles must end: it takes a deadline in seconds and exits 4, and the runner reports the rejoin command. (Tasks 3 and 5)

---

## File structure

- `host/apply.sh` (new): the SMF start method; the step loop. Replaces `host/run-step.sh` (deleted).
- `host/homicron-apply.xml` (new): the manifest.
- `host/start-apply.sh` (new): validate and import the manifest, write the marker, start the run.
- `host/watch-apply.sh` (new): stream `apply.log` from a line offset until the service settles.
- `host/80-voxel-images.sh` (new): the image build step.
- `bin/homicron` (modify): `apply` ships, starts, watches; `wait_for_reboot` replaces `reboot_box`.
- `test/apply.bats`, `test/start-apply.bats`, `test/watch-apply.bats`, `test/step-voxel-images.bats` (new); `test/homicron.bats` (modify); `test/run-step.bats` (deleted).
- `README.md`, `hosts/README.md` (modify).

Each task is one commit on the branch `apply-under-smf`.

---

### Task 1: `host/apply.sh`, the step loop as an SMF method

**Files:**
- Create: `host/apply.sh`
- Delete: `host/run-step.sh`, `test/run-step.bats`
- Test: `test/apply.bats`

**Interfaces:**
- Consumes: `$HOMICRON_DIR/host.env`, steps `$HOMICRON_DIR/[0-9][0-9]-*.sh`, `kstat -p unix:0:system_misc:boot_time` (prints `unix:0:system_misc:boot_time<TAB><seconds>`), `reboot`.
- Produces: `apply.log` protocol lines (Global Constraints); the marker file `$HOMICRON_STATE_DIR/apply-requested` whose content is the kernel boot time (seconds) recorded by `start-apply.sh` (Task 2), rewritten by `apply.sh` to `<boot time> <step>` when it reboots for a step; exit 0 converged or nothing to do, exit 1 a step failed or `host.env` missing.

- [ ] **Step 1: Write the failing tests**

`test/apply.bats`, `setup`: `fakes_setup`; export `HOMICRON_DIR=$BATS_TEST_TMPDIR/opt`, `HOMICRON_LOG_DIR=$BATS_TEST_TMPDIR/log`, `HOMICRON_STATE_DIR=$BATS_TEST_TMPDIR/state`; `mkdir -p` the first and last; copy `host/apply.sh` into `$HOMICRON_DIR`; write `host.env` with `HOMICRON_USER=vmuser\nSWAP_SIZE=4G\n`; write steps `10-a.sh` (`echo "user=$HOMICRON_USER swap=$SWAP_SIZE"; exit 0`) and `20-b.sh` (`echo b; exit 0`); `make_fake kstat 0 $'unix:0:system_misc:boot_time\t1000'`; `make_fake reboot`; marker `printf '1000\n' > "$HOMICRON_STATE_DIR/apply-requested"`. `LOG=$HOMICRON_LOG_DIR/apply.log`.

```bash
@test "no marker: exits 0 and runs nothing" {
  rm "$HOMICRON_STATE_DIR/apply-requested"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "runs the steps in order with the environment, logs each, deletes the marker, says complete" {
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 0 ]
  grep -q '^=== run ' "$LOG"
  ! grep -q 'resumed' "$LOG"
  [[ "$(grep -n '^==> ' "$LOG" | cut -d: -f2- | tr '\n' ' ')" == "==> 10-a.sh ==> 20-b.sh " ]]
  grep -q 'user=vmuser swap=4G' "$LOG"
  grep -q 'user=vmuser swap=4G' "$HOMICRON_LOG_DIR/10-a.sh.log"
  grep -q '^+ echo' "$HOMICRON_LOG_DIR/10-a.sh.log"
  [[ "$(tail -1 "$LOG")" == "apply complete" ]]
  [ ! -e "$HOMICRON_STATE_DIR/apply-requested" ]
}

@test "a failing step logs the status, exits 1, keeps the marker, runs no later step" {
  printf '#!/bin/bash\nexit 3\n' > "$HOMICRON_DIR/10-a.sh"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$(tail -1 "$LOG")" == "step 10-a.sh failed with status 3" ]]
  ! grep -q '^==> 20-b.sh' "$LOG"
  [ -e "$HOMICRON_STATE_DIR/apply-requested" ]
}

@test "exit 10 logs the reboot, records the step in the marker, reboots once, runs no later step" {
  printf '#!/bin/bash\nexit 10\n' > "$HOMICRON_DIR/10-a.sh"
  run "$HOMICRON_DIR/apply.sh"
  [[ "$(tail -1 "$LOG")" == "rebooting for 10-a.sh" ]]
  [ "$(fake_calls | grep -c '^reboot$')" -eq 1 ]
  [[ "$(cat "$HOMICRON_STATE_DIR/apply-requested")" == "1000 10-a.sh" ]]
  ! grep -q '^==> 20-b.sh' "$LOG"
}

@test "a marker from an earlier boot gives the resumed header" {
  printf '900\n' > "$HOMICRON_STATE_DIR/apply-requested"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 0 ]
  grep -q '^=== run .* (resumed after reboot)$' "$LOG"
}

@test "a step that asks for a second reboot in a row fails instead of rebooting" {
  printf '900 10-a.sh\n' > "$HOMICRON_STATE_DIR/apply-requested"
  printf '#!/bin/bash\nexit 10\n' > "$HOMICRON_DIR/10-a.sh"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 1 ]
  refute_called '^reboot$'
  [[ "$(tail -1 "$LOG")" == "step 10-a.sh failed with status 10 (asked for a second reboot)" ]]
}

@test "a missing host.env logs and exits 1" {
  rm "$HOMICRON_DIR/host.env"
  run "$HOMICRON_DIR/apply.sh"
  [ "$status" -eq 1 ]
  grep -q 'host.env' "$LOG"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/apply.bats`
Expected: every test fails; the first with `apply.sh: No such file`.

- [ ] **Step 3: Implement `host/apply.sh`**

`set -o nounset -o pipefail`, no `errexit`. Variables from the Global Constraints with their overrides; `marker=$state_dir/apply-requested`, `log=$log_dir/apply.log`. `boot_time()` reads kstat's second field. Order: no marker, exit 0; `mkdir -p "$log_dir"`; missing `host.env`, log `host.env missing in $dir; nothing run` and exit 1; source `host.env` with `allexport`, export `HOMICRON_DIR`; write the header, `(resumed after reboot)` when the marker's first field differs from `boot_time`; `rebooted_for` is the marker's second field (empty if none). For each step: `==> <step>` to the log, `bash -x "$dir/$step" 2>&1 | tee -a "$log_dir/$step.log" >> "$log"` after the dated header in the step log as `run-step.sh` wrote it, `status=${PIPESTATUS[0]}`. Status 10 with `rebooted_for == step` is a failure with the `(asked for a second reboot)` suffix and exit 1; status 10 otherwise writes `<boot time> <step>` to the marker, logs `rebooting for <step>`, runs `reboot`, and exits 0 (the test's fake returns). Other nonzero logs the failure line and exits 1. After the loop, `rm -f "$marker"`, log `apply complete`, exit 0.

- [ ] **Step 4: Run the tests to verify they pass; delete `run-step.sh`**

Run: `git rm -q host/run-step.sh test/run-step.bats && bats test/apply.bats && test/lint.sh && test/run-tests.sh`
Expected: `apply.bats` 7 passing; the full suite green (the runner tests still name `run-step.sh` in fake ssh calls but never run it).

- [ ] **Step 5: Commit**

```bash
git add host/apply.sh test/apply.bats
git commit -m "apply.sh: the step loop as an SMF start method, replacing run-step.sh"
```

---

### Task 2: the manifest and `host/start-apply.sh`

**Files:**
- Create: `host/homicron-apply.xml`, `host/start-apply.sh`
- Test: `test/start-apply.bats`

**Interfaces:**
- Consumes: `svccfg validate <file>`, `svccfg import <file>`, `svcs -H -o state site/homicron-apply` (prints the state, `offline*` while the method runs; exits 1 with a message on stderr when the service does not exist), `svcadm clear|enable|restart site/homicron-apply`, `kstat` as in Task 1.
- Produces: the marker with the boot time as its content (Task 1 reads it); stdout one line: `an apply is already running on the box`, `cleared the failed run and started`, `enabled and started`, `restarted`; exit 0, or 2 on validation failure, 1 on an unexpected state.

- [ ] **Step 1: Write the failing tests**

`setup`: `fakes_setup`; export `HOMICRON_DIR`, `HOMICRON_STATE_DIR`, `HOMICRON_MANIFEST_DIR=$BATS_TEST_TMPDIR/manifest`; copy `host/start-apply.sh` and `host/homicron-apply.xml` into `$HOMICRON_DIR`; `make_fake svccfg`, `make_fake svcadm`, `make_fake svcs 0 disabled`, `make_fake kstat 0 $'unix:0:system_misc:boot_time\t1000'`.

```bash
@test "manifest is well-formed xml" {
  run xmllint --noout "$BATS_TEST_DIRNAME/../host/homicron-apply.xml"
  [ "$status" -eq 0 ]
}

@test "validates, installs, imports the manifest, writes the marker, enables a disabled service" {
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  assert_called "^svccfg validate $HOMICRON_DIR/homicron-apply.xml$"
  cmp -s "$HOMICRON_DIR/homicron-apply.xml" "$HOMICRON_MANIFEST_DIR/homicron-apply.xml"
  assert_called "^svccfg import $HOMICRON_MANIFEST_DIR/homicron-apply.xml$"
  [[ "$(cat "$HOMICRON_STATE_DIR/apply-requested")" == "1000" ]]
  assert_called '^svcadm enable site/homicron-apply$'
  [[ "$output" == "enabled and started" ]]
}

@test "a validation failure stops before copy, import, or marker" {
  printf 'echo "bad manifest" >&2; exit 1\n' > "$FAKE_BIN/svccfg.script"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad manifest"* ]]
  refute_called '^svccfg import'
  [ ! -e "$HOMICRON_MANIFEST_DIR/homicron-apply.xml" ]
  [ ! -e "$HOMICRON_STATE_DIR/apply-requested" ]
}

@test "maintenance is cleared, online is restarted, a missing service is enabled" {
  for pair in 'maintenance:clear:cleared the failed run and started' 'online:restart:restarted'; do
    IFS=: read -r state verb line <<< "$pair"
    : > "$FAKE_LOG"
    printf 'echo %s\n' "$state" > "$FAKE_BIN/svcs.script"
    run "$HOMICRON_DIR/start-apply.sh"
    [ "$status" -eq 0 ]
    assert_called "^svcadm $verb site/homicron-apply$"
    [[ "$output" == "$line" ]]
  done
  : > "$FAKE_LOG"
  printf "echo \"svcs: Pattern 'site/homicron-apply' doesn't match any instances\" >&2; exit 1\n" > "$FAKE_BIN/svcs.script"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  assert_called '^svcadm enable site/homicron-apply$'
}

@test "a running method is left alone" {
  printf 'echo "offline*"\n' > "$FAKE_BIN/svcs.script"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
  [[ "$output" == "an apply is already running on the box" ]]
}

@test "an unexpected state is reported and exits 1" {
  printf 'echo degraded\n' > "$FAKE_BIN/svcs.script"
  run "$HOMICRON_DIR/start-apply.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *degraded* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/start-apply.bats`
Expected: all fail; the xml test with `failed to load external entity`.

- [ ] **Step 3: Write `host/homicron-apply.xml`**

Copy the shape of `firstboot/homicron-firstboot.xml`: bundle name `homicron-apply`, service `site/homicron-apply` version 1, `create_default_instance enabled='false'`, `single_instance`, one dependency `multi-user-server` on `svc:/milestone/multi-user-server:default` (`require_all`, `restart_on='none'`), start method `/opt/homicron/apply.sh` with `timeout_seconds='0'`, stop `:true` with 3, `startd/duration` `transient`, stability `Unstable`, common name `homicron apply: run the host steps`. The header comment says `bin/homicron` ships it in `host/` and `start-apply.sh` imports it on every apply.

- [ ] **Step 4: Implement `host/start-apply.sh`**

`set -o errexit -o nounset -o pipefail`. `state()` prints `svcs -H -o state site/homicron-apply 2>/dev/null || echo missing`. Validate (on failure print svccfg's output and exit 2; capture with `|| { ...; exit 2; }` since `errexit` is on), `mkdir -p` the manifest and state dirs, `cp`, `svccfg import`, write `boot_time` to the marker, then `case $(state)`: `offline*)` print and exit 0; `maintenance)` clear; `disabled|uninitialized|missing)` enable; `online)` restart; `*)` print `service is in state <state>; not started` and exit 1.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/start-apply.bats && test/lint.sh`
Expected: 6 passing, lint clean.

- [ ] **Step 6: Commit**

```bash
git add host/homicron-apply.xml host/start-apply.sh test/start-apply.bats
git commit -m "start-apply.sh and the site/homicron-apply manifest"
```

---

### Task 3: `host/watch-apply.sh`

**Files:**
- Create: `host/watch-apply.sh`
- Test: `test/watch-apply.bats`

**Interfaces:**
- Consumes: `$HOMICRON_LOG_DIR/apply.log`, `svcs -H -o state site/homicron-apply`, `sleep 1`.
- Produces: `watch-apply.sh <lines-already-seen> <max-seconds>`; prints the log lines after the offset; exit 0 `online`, 1 `maintenance`, 3 any other settled state (prints `service is <state>`), 4 when `max-seconds` of polling pass while still `offline*` (prints nothing extra).

- [ ] **Step 1: Write the failing tests**

`setup`: `fakes_setup`; export `HOMICRON_LOG_DIR`; copy the script to `$BATS_TEST_TMPDIR/watch-apply.sh`; `make_fake sleep`; `make_fake svcs 0 online`; `LOG=$HOMICRON_LOG_DIR/apply.log`; `mkdir -p "$HOMICRON_LOG_DIR"`; `printf 'one\ntwo\nthree\n' > "$LOG"`.

```bash
@test "prints the lines after the offset and exits 0 when online" {
  run "$BATS_TEST_TMPDIR/watch-apply.sh" 1 60
  [ "$status" -eq 0 ]
  [[ "$output" == $'two\nthree' ]]
}

@test "maintenance exits 1 after printing the rest" {
  make_fake svcs 0 maintenance
  run "$BATS_TEST_TMPDIR/watch-apply.sh" 3 60
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "keeps polling while the method runs, then prints what arrived" {
  printf 'n=$(grep -c "^svcs" "$FAKE_LOG"); if (( n < 3 )); then echo "offline*"; else echo online; fi; (( n == 2 )) && echo four >> "$LOG"; exit 0\n' > "$FAKE_BIN/svcs.script"
  export LOG
  run "$BATS_TEST_TMPDIR/watch-apply.sh" 3 60
  [ "$status" -eq 0 ]
  [[ "$output" == "four" ]]
  [ "$(fake_calls | grep -c '^sleep 1$')" -eq 2 ]
}

@test "a missing log or an offset past the end prints nothing and still settles" {
  rm "$LOG"
  run "$BATS_TEST_TMPDIR/watch-apply.sh" 0 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'one\n' > "$LOG"
  run "$BATS_TEST_TMPDIR/watch-apply.sh" 5 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "another settled state exits 3 and names it" {
  make_fake svcs 0 disabled
  run "$BATS_TEST_TMPDIR/watch-apply.sh" 3 60
  [ "$status" -eq 3 ]
  [[ "$output" == "service is disabled" ]]
}

@test "a method still running after max-seconds exits 4" {
  make_fake svcs 0 'offline*'
  run "$BATS_TEST_TMPDIR/watch-apply.sh" 3 2
  [ "$status" -eq 4 ]
  [ "$(fake_calls | grep -c '^sleep 1$')" -eq 2 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/watch-apply.bats`
Expected: all fail with `No such file`.

- [ ] **Step 3: Implement `host/watch-apply.sh`**

`set -o nounset -o pipefail`. `seen=${1:?}`, `max=${2:?}`, `waited=0`. Loop: `total=$(wc -l < "$log" 2>/dev/null || echo 0)`; if `total > seen`, `sed -n "$((seen + 1)),\$p" "$log"` and `seen=$total`; `state=$(svcs -H -o state site/homicron-apply 2>/dev/null || echo missing)`; `offline*` or `missing`: exit 4 when `waited >= max`, else `sleep 1`, `waited++`, continue; `online` exit 0; `maintenance` exit 1; else print `service is $state`, exit 3. (`missing` counts as running so a watcher started a moment before the import does not fail.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/watch-apply.bats && test/lint.sh`
Expected: 6 passing, lint clean.

- [ ] **Step 5: Commit**

```bash
git add host/watch-apply.sh test/watch-apply.bats
git commit -m "watch-apply.sh: stream apply.log from a line offset until the service settles"
```

---

### Task 4: step 80, the voxel images

**Files:**
- Create: `host/80-voxel-images.sh`
- Test: `test/step-voxel-images.bats`

**Interfaces:**
- Consumes: `lib.sh` (`as_user`, `step_main`, `log`), `HOMICRON_USER`, `HOMICRON_HOME` override of `/home`; `voxel image list` output whose data lines start with two spaces and the image name as the first field, as in:

```
images under rpool/falcon/img:

  IMAGE                                              SIZE   CREATED                COMMIT
  voxel-frr-proto                                    1.31G  Mon Nov  2 23:40 2026  -
  voxel-cp-77901ac4bb2d6e1ac6dd7380b3758129b73f69cd  10.2G  Mon Nov  2 23:37 2026  77901ac4bb2d6e1ac6dd7380b3758129b73f69cd
```

- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing tests**

`setup` as in `test/step-voxel-conf.bats`: `fakes_setup`, `HOMICRON_USER=vmuser`, `HOMICRON_HOME`, `make_fake su` with the same `su.script` as `test/step-voxel.bats` (runs the `-c` command with the fake PATH), `make_fake pfexec` whose script runs `"$@"`, and a fake `voxel` at the path the step uses (`$HOMICRON_HOME/vmuser/src/voxel/target/release/voxel`, made executable) that answers `image list` from the file `$IMAGES` (one name per line, printed in the layout above) and logs `image create` and `image create-frr proto` to `$FAKE_LOG` while appending the new name to `$IMAGES`.

```bash
@test "both images present: nothing runs" {
  printf 'voxel-frr-proto\nvoxel-cp-77901ac4bb2d6e1ac6dd7380b3758129b73f69cd\n' > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called 'image create'
}

@test "no images: builds cp then frr through pfexec as the user" {
  : > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$(fake_calls | grep -o 'image create.*' | tr '\n' '|')" == 'image create|image create-frr proto|' ]]
  assert_called '^su - vmuser -c pfexec .*voxel image create$'
}

@test "only the missing image is built" {
  printf 'voxel-cp-abc\n' > "$IMAGES"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called 'image create$'
  assert_called 'image create-frr proto$'
}

@test "a failed cp build stops before frr and the step fails" {
  : > "$IMAGES"
  printf 'exit 1\n' > "$FAKE_BIN/voxel-create-fails"   # the fake voxel exits 1 on create when this file exists
  run "$STEP"
  [ "$status" -ne 0 ]
  refute_called 'create-frr'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/step-voxel-images.bats`
Expected: all fail with `80-voxel-images.sh: No such file`.

- [ ] **Step 3: Implement `host/80-voxel-images.sh`**

Header: end state is both images registered. `images()` is `as_user "$voxel image list" | awk 'NR > 3 && NF { print $1 }'`. `have_cp()` matches `^voxel-cp-`, `have_frr()` matches `^voxel-frr-proto$`. `check` is both. `apply`: `have_cp || as_user "pfexec $voxel image create"`; `have_frr || as_user "pfexec $voxel image create-frr proto"`. `errexit` makes a failed first build end `apply`, and `step_main`'s second `check` fails the step.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/step-voxel-images.bats && test/lint.sh`
Expected: 4 passing, lint clean.

- [ ] **Step 5: Commit**

```bash
git add host/80-voxel-images.sh test/step-voxel-images.bats
git commit -m "Step 80: build the voxel images"
```

---

### Task 5: the runner ships, starts, and watches

**Files:**
- Modify: `bin/homicron` (header comment; `reboot_box` → `wait_for_reboot`; remove `run_step`, `step_failed`; rewrite `apply`)
- Test: `test/homicron.bats`

**Interfaces:**
- Consumes: Task 2's `start-apply.sh` lines and exit codes; Task 3's `watch-apply.sh <seen> <max>` exit codes; `svcs -H -o state,stime site/homicron-apply` over ssh (two whitespace-separated fields; exit 1 when missing); `grep -n '^=== run' /var/log/homicron/apply.log` and `wc -l < /var/log/homicron/apply.log` over ssh.
- Produces: the user-visible runner behavior in the spec.

- [ ] **Step 1: Rewrite the step-loop tests in `test/homicron.bats`**

Keep `setup`, `capture_sent`, and every test not named here. Delete "runs steps in order over ssh with the port", the four reboot tests, "exit 255 reports unreachable and exits 1" (replaced below), and "other failures stop, print the log, and pass the status through". Add a helper that writes the fake ssh for a given scenario: the fake matches `$*` and answers `svcs` with `$STATE` (a file; default `disabled` printed as `disabled -`), `wc -l` with `0`, `grep -n` with nothing, `start-apply.sh` with `enabled and started`, `watch-apply.sh` with the content of `$STREAM` and exit `$WATCH_EXIT`, `kstat` as the old tests did. Add:

```bash
@test "ships, starts the service, streams the log, and says complete" {
  printf 'line one\napply complete\n' > "$STREAM"; echo 0 > "$WATCH_EXIT"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^rsync .* root@box.local:/opt/homicron/$'
  assert_called 'root@box.local /opt/homicron/start-apply.sh$'
  assert_called 'root@box.local /opt/homicron/watch-apply.sh 0 7200$'
  [[ "$output" == *$'enabled and started\nline one\napply complete' ]]
  refute_called 'run-step'
  refute_called 'pfexec'
}

@test "a running apply is attached from its run header, with nothing shipped" {
  printf 'offline* 10:00:00\n' > "$STATE"
  printf 'case "$*" in *grep*) echo "7:=== run x"; exit 0;; esac\n' > "$FAKE_BIN/ssh.extra"
  printf 'rest\napply complete\n' > "$STREAM"; echo 0 > "$WATCH_EXIT"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  refute_called '^rsync'
  refute_called 'start-apply.sh'
  assert_called 'watch-apply.sh 6 '
  [[ "$output" == *"already running on the box since 10:00:00"* ]]
}

@test "a reboot line then 255 waits for a new boot time and reconnects with the line count" {
  # first watch: two lines then 255; kstat changes after the first read; second watch: completes
  ...fake: watch call 1 prints 'x\nrebooting for 30-pkg.sh' exit 255; kstat n<=1 -> 1000, else 1001; watch call 2 prints 'apply complete' exit 0
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  refute_called 'root@box.local reboot$'
  assert_called 'watch-apply.sh 0 '
  assert_called 'watch-apply.sh 2 '
  [[ "$output" == *"waiting for the box to come back"* ]]
}

@test "255 without a reboot line is unreachable" {
  printf 'x\n' > "$STREAM"; echo 255 > "$WATCH_EXIT"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach box.local"* ]]
}

@test "rsync failing to connect is unreachable before any start"   # keep the existing test's body

@test "a failed step exits with its status and names it" {
  printf 'some output\nstep 10-a.sh failed with status 3\n' > "$STREAM"; echo 1 > "$WATCH_EXIT"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 3 ]
  [[ "${lines[-1]}" == "homicron: step 10-a.sh failed with status 3" ]]
  refute_called 'cat /var/log'
}

@test "a watch timeout says how to rejoin" {
  echo 4 > "$WATCH_EXIT"; : > "$STREAM"
  HOMICRON_APPLY_TIMEOUT=30 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  assert_called 'watch-apply.sh 0 30$'
  [[ "$output" == *"still running after 30s; rejoin with homicron apply box"* ]]
}

@test "start-apply failing stops with its output" {
  # fake start-apply.sh prints 'bad manifest' and exits 2
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad manifest"* ]]
  refute_called 'watch-apply.sh'
}
```

The `...` in the reboot test is the implementer's fake-ssh script; its assertions are fixed as written. The keepalive test keeps asserting that the `watch-apply.sh` ssh carries `ServerAliveInterval`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/homicron.bats`
Expected: the new tests fail (`run-step` still called, no `start-apply.sh`); the kept tests pass.

- [ ] **Step 3: Rewrite `apply` in `bin/homicron`**

Header comment: the runner ships `host/` and watches `site/homicron-apply`. `apply_timeout=${HOMICRON_APPLY_TIMEOUT:-7200}`. New functions: `service_state()` (remote `svcs -H -o state,stime site/homicron-apply` with stderr dropped, prints `missing -` on failure); `log_lines()` (remote `wc -l < /var/log/homicron/apply.log 2>/dev/null || echo 0`); `run_header_line()` (remote `grep -n '^=== run' .../apply.log | tail -1 | cut -d: -f1`, empty when none); `wait_for_reboot()` (the body of `reboot_box` without the two `remote reboot` sends and the resend branch: wait until the boot time changes, or ssh drops and returns, within `reboot_timeout`, printing `waiting for the box to come back`); `watch(seen)` runs `remote "$remote_dir/watch-apply.sh $seen $remaining"` through `while IFS= read -r line` from a process substitution, prints each line, counts them in a global `seen`, remembers the last line in `last_line`, and returns the remote status from `wait`. `apply`: load, env, keys; `read -r state stime <<< "$(service_state)"`; if `state == offline*`, print the attaching line, `seen=$(( $(run_header_line) - 1 ))` (0 when empty), else `seen=$(log_lines)`, rsync the three things, run `start-apply.sh` with its output printed (nonzero: die with that output, status 1; if the output is the already-running line, recompute `seen` from the header). Then loop on `watch`: 0 → exit 0 (the streamed `apply complete` line is the last output); 1 → parse `last_line` with the regex `^step (.+) failed with status ([0-9]+)`, die with that message and status; 255 → if `last_line` matches `^rebooting for `, `wait_for_reboot` and continue, else `unreachable`; 4 → die `apply still running after ${apply_timeout}s; rejoin with homicron apply $name`; other → die naming the status and the log path.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/homicron.bats && test/lint.sh && test/run-tests.sh`
Expected: all passing, lint clean, full suite green.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron test/homicron.bats
git commit -m "Runner: ship host/, start site/homicron-apply, stream its log"
```

---

### Task 6: documentation

**Files:**
- Modify: `README.md` (install steps 6 and 7, the stages table, the layout table), `hosts/README.md`

- [ ] **Step 1: Edit the README**

Step 6: `apply` ships `host/` and runs every step on the box as the SMF service `site/homicron-apply`, including the voxel image build (30 to 45 minutes); the output streams to the terminal; Ctrl-C leaves the run going on the box and the same command rejoins it; a failed step leaves the service in `maintenance` and the next `apply` clears it. Remove step 7. In the stages table, the `host/NN-*.sh` row's "Where" becomes `on the box, as the SMF service site/homicron-apply` and the list gains `the voxel images`. The layout table (the `test/run-tests.sh` neighborhood) names `host/apply.sh`, `host/start-apply.sh`, `host/watch-apply.sh`, `host/homicron-apply.xml`, and the log `/var/log/homicron/apply.log`. Delete every mention of `run-step.sh`.

- [ ] **Step 2: Edit `hosts/README.md`**

After the `HOMICRON_ADDR` paragraph: one sentence that `apply` attaches to an apply already running on the box instead of starting a second one, and ships nothing in that case.

- [ ] **Step 3: Check and commit**

Run: `grep -rn 'run-step' README.md hosts/README.md bin host test; test/run-tests.sh | tail -1`
Expected: no matches; the suite's last line is the final `ok`.

```bash
git add README.md hosts/README.md
git commit -m "Docs: apply runs on the box as an SMF service and builds the images"
```

---

## Rehearsal (after the final review, before merge)

On the Arch host as `arch-rehearsal-host` describes: fresh install, then `HOMICRON_ADDR=archlinux.tailcc8891.ts.net bin/homicron apply vm`; expect `enabled and started`, the step 30 reboot announced as `rebooting for 30-pkg.sh`, `waiting for the box to come back`, the stream resuming, and Ctrl-C during step 40 followed by a second `apply` that prints the attaching line and continues. Stop once step 80 has started `voxel image create` if time is short. Then `bin/homicron apply homicron00` on the real box: expect `enabled and started`, steps 10 to 70 as no-ops, step 80 `already in the desired state`, `apply complete`.
