# The rack at boot: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After any boot of a homicron host, the voxel rack is destroyed and relaunched by an SMF service, and every setting that launch depends on is converged by `apply`.

**Architecture:** Four host steps (25 network layout, 85 voxel.toml keys, 87 propolis binary, 90 rack service) follow the `lib.sh` check/apply pattern, and the service `svc:/site/voxel-rack:default` is a transient SMF service whose start method destroys and relaunches the rack as the login user through `pfexec`, with a `require_all` dependency on `site/homicron-apply` so the rack never launches during an apply. Five new hosts variables carry the per-machine layout.

**Tech Stack:** bash, SMF manifests (XML), bats with the fakes in `test/helpers/fakes.bash`, shellcheck, xmllint.

**Spec:** `docs/superpowers/specs/2026-11-02-rack-at-boot-design.md`

## Global Constraints

- Every step script starts with `set -o errexit -o pipefail -o nounset`, sources `lib.sh`, defines `check` and `apply`, and ends with `step_main`. Test overrides are `HOMICRON_HOME` for `/home` and, for new paths, the variables named in each task.
- voxel runs as the login user: `as_user "pfexec $voxel …"` where `voxel="$home_root/$HOMICRON_USER/src/voxel/target/release/voxel"`.
- Hosts values hold only `[A-Za-z0-9._/:@%+,-]`.
- SMF method exit codes: 0 success, 95 fatal (straight to maintenance), 96 configuration error. No method exits 1.
- Log lines a person reads start with `homicron: ` in steps (`log`), and the rack log is `/var/log/voxel-rack.log` with `=== start <UTC time>` headers.
- Plain English in every comment, log line, and document: short sentences, no contractions, no semicolons.
- Commit after every task with a one-line subject in the repository's style (`Step 25: …`, `Rack service: …`, `Docs: …`) and the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

- A `MGMT_LINKS` value with spaces or a trailing comma must not append a line for an empty link name. Task 2 tests an empty element.
- Two `voxel-cp-*` images with `VOXEL_CP_IMAGE` empty must stop with both names in the message, never pick one. Task 3 tests it.
- A truncated propolis download must never be installed: the digest check runs on the part file and a mismatch deletes it. Task 4 tests it.
- The start method must not exit nonzero when the hook fails, and must exit 95 when the launch output holds `rack-init FAILED` even though `launch complete` follows it. Task 5 tests both.
- `VOXEL_RACK=no` on a box with a rack destroys it. Task 6 tests that the step runs `svcadm disable`, and the README says what that does.

---

### Task 1: hosts variables

**Files:**
- Modify: `bin/homicron:40-41` (`host_vars`), `bin/homicron:193` area (defaults in `load_host`)
- Modify: `hosts/README.md:15-27` (the table)
- Test: `test/homicron.bats`

**Interfaces:**
- Produces: `host.env` on the box always holds `VOXEL_EXTERNAL_MODE`, `VOXEL_EXTERNAL_UPLINK`, `VOXEL_CP_IMAGE`, `MGMT_LINKS`, `VOXEL_RACK`, with defaults `lan`, empty, empty, empty, `yes`.

- [ ] **Step 1: Write the failing test** in `test/homicron.bats`, after "sends a resolved host.env with defaults and environment overrides":

```bash
@test "ships the rack variables with their defaults" {
  capture_sent
  MGMT_LINKS=igb1 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  grep -qx 'VOXEL_EXTERNAL_MODE=lan' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_EXTERNAL_UPLINK=' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_CP_IMAGE=' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'MGMT_LINKS=igb1' "$BATS_TEST_TMPDIR/sent.env"
  grep -qx 'VOXEL_RACK=yes' "$BATS_TEST_TMPDIR/sent.env"
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats test/homicron.bats -f "rack variables"`
Expected: FAIL at `VOXEL_EXTERNAL_MODE=lan` (the variable is unknown, exit 2).

- [ ] **Step 3: Add the five names to `host_vars` and the five defaults beside `VOXEL_SLED_MEMORY_GB` in `load_host`**, in the same `export VAR=${VAR:-default}` form.

- [ ] **Step 4: Run the test file**

Run: `bats test/homicron.bats`
Expected: all PASS.

- [ ] **Step 5: Add five rows to the table in `hosts/README.md`**, copied from the spec's "Hosts variables" table, plus one sentence after the table: a link removed from `MGMT_LINKS` keeps its dhcpagent line until a person deletes it, and `VOXEL_RACK=no` destroys a running rack.

- [ ] **Step 6: Lint and commit**

Run: `test/lint.sh`
Expected: exit 0.

```bash
git add bin/homicron hosts/README.md test/homicron.bats
git commit -m "Runner: the five rack variables and their defaults"
```

---

### Task 2: step 25, network layout and time

**Files:**
- Create: `host/25-network.sh`
- Test: `test/step-network.bats`

**Interfaces:**
- Consumes: `MGMT_LINKS` from `host.env`.
- Produces: `/etc/default/dhcpagent` lines `<link>.PARAM_IGNORE_LIST=3`; path override `HOMICRON_DHCPAGENT_DEFAULTS` (default `/etc/default/dhcpagent`).

- [ ] **Step 1: Write the failing tests** in `test/step-network.bats`. Setup: `fakes_setup`; `export HOMICRON_DHCPAGENT_DEFAULTS="$BATS_TEST_TMPDIR/dhcpagent"` with a two-line stock file (`PARAM_REQUEST_LIST=…`, `PARAM_IGNORE_LIST=`); fakes `svcs`, `svcadm`, `ipadm`, `netstat`. `svcs` prints the content of `$BATS_TEST_TMPDIR/chrony-state` (default `online`). `netstat` prints the content of `$BATS_TEST_TMPDIR/routes` (default one `default 192.168.0.1 UG 2 0 igb0` line in `netstat -rn -f inet` layout).

```bash
@test "chrony online, no management links: nothing runs" {
  MGMT_LINKS= run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'; refute_called '^ipadm'
}

@test "enables chrony when it is not online" {
  echo disabled > "$BATS_TEST_TMPDIR/chrony-state"
  printf 'echo online > "%s"\n' "$BATS_TEST_TMPDIR/chrony-state" > "$FAKE_BIN/svcadm.script"
  MGMT_LINKS= run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^svcadm enable -s chrony$'
}

@test "appends one line per management link and recycles each lease once" {
  MGMT_LINKS=igb1,igb2 run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx 'igb1.PARAM_IGNORE_LIST=3' "$HOMICRON_DHCPAGENT_DEFAULTS"
  grep -qx 'igb2.PARAM_IGNORE_LIST=3' "$HOMICRON_DHCPAGENT_DEFAULTS"
  assert_called '^ipadm delete-addr igb1/v4$'
  assert_called '^ipadm create-addr -T dhcp -w 20 igb1/v4$'
  [[ "$output" == *"recycling the lease on igb1, an ssh on it drops"* ]]
  MGMT_LINKS=igb1,igb2 run "$STEP"
  [ "$(grep -c 'igb1.PARAM_IGNORE_LIST=3' "$HOMICRON_DHCPAGENT_DEFAULTS")" -eq 1 ]
}

@test "a line already present is not recycled" {
  echo 'igb1.PARAM_IGNORE_LIST=3' >> "$HOMICRON_DHCPAGENT_DEFAULTS"
  MGMT_LINKS=igb1 run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^ipadm'
}

@test "an empty element in MGMT_LINKS adds no line" {
  MGMT_LINKS=igb1, run "$STEP"
  [ "$status" -eq 0 ]
  ! grep -q '^\.PARAM_IGNORE_LIST' "$HOMICRON_DHCPAGENT_DEFAULTS"
}

@test "a default route left on a management link fails the step" {
  printf 'default 192.168.0.1 UG 2 0 igb1\n' > "$BATS_TEST_TMPDIR/routes"
  echo 'igb1.PARAM_IGNORE_LIST=3' >> "$HOMICRON_DHCPAGENT_DEFAULTS"
  MGMT_LINKS=igb1 run "$STEP"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bats test/step-network.bats`
Expected: FAIL, the step file does not exist.

- [ ] **Step 3: Write `host/25-network.sh`.** Functions: `links()` splits `MGMT_LINKS` on commas and drops empty elements; `has_line LINK`; `mgmt_default_route` greps `netstat -rn -f inet` for a `^default ` line whose last field is a management link; `chrony_online`; `check` is `chrony_online && every has_line && ! mgmt_default_route`; `apply` enables chrony when needed and, per link without a line, logs the recycle warning, appends a comment and the line, then runs the two `ipadm` commands. The second `check` in `step_main` is what fails the step when a default route remains.

- [ ] **Step 4: Run the tests**

Run: `bats test/step-network.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

Run: `test/lint.sh`

```bash
git add host/25-network.sh test/step-network.bats
git commit -m "Step 25: management links without a default route, chrony on"
```

---

### Task 3: step 85, voxel.toml keys

**Files:**
- Rename: `host/70-voxel-conf.sh` to `host/85-voxel-conf.sh` (`git mv`)
- Modify: `host/85-voxel-conf.sh`
- Modify: `test/step-voxel-conf.bats` (the `STEP` path and new tests)

**Interfaces:**
- Consumes: `VOXEL_SLEDS`, `VOXEL_SLED_MEMORY_GB`, `FALCON_DATASET`, `VOXEL_CP_IMAGE`, `VOXEL_EXTERNAL_MODE`, `VOXEL_EXTERNAL_UPLINK`.
- Produces: the seven keys in the spec's table. `falcon.propolis_binary` is not this step's.

- [ ] **Step 1: `git mv host/70-voxel-conf.sh host/85-voxel-conf.sh`** and point `STEP` in the test at the new name. Run `bats test/step-voxel-conf.bats`; expected: the four existing tests PASS.

- [ ] **Step 2: Write the failing tests.** Extend `setup`: `export VOXEL_CP_IMAGE= VOXEL_EXTERNAL_MODE=lan VOXEL_EXTERNAL_UPLINK=`; `make_fake zfs` printing the content of `$BATS_TEST_TMPDIR/images` (default `rpool/falcon/img/voxel-cp-abc` and `rpool/falcon/img/voxel-frr-proto`, one per line); extend the existing "every value already matches" fixture with `image.cp voxel-cp-abc`, `image.frr voxel-frr-proto`, `external.mode lan`.

```bash
@test "selects the one cp image under the dataset" {
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^zfs list -H -o name -r rpool/falcon/img$'
  assert_called '^voxel config set image.cp voxel-cp-abc$'
  assert_called '^voxel config set image.frr voxel-frr-proto$'
}

@test "lists under FALCON_DATASET when set" {
  printf 'fast/falcon/img/voxel-cp-abc\n' > "$BATS_TEST_TMPDIR/images"
  FALCON_DATASET=fast/falcon run "$STEP"
  assert_called '^zfs list -H -o name -r fast/falcon/img$'
}

@test "VOXEL_CP_IMAGE wins over the search" {
  VOXEL_CP_IMAGE=voxel-cp-xyz run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^zfs'
  assert_called '^voxel config set image.cp voxel-cp-xyz$'
}

@test "no cp image exits 1 and names step 80" {
  printf 'rpool/falcon/img/voxel-frr-proto\n' > "$BATS_TEST_TMPDIR/images"
  run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no voxel-cp image under rpool/falcon/img; step 80 builds one"* ]]
}

@test "two cp images exit 1 with both names" {
  printf 'rpool/falcon/img/voxel-cp-abc\nrpool/falcon/img/voxel-cp-def\n' > "$BATS_TEST_TMPDIR/images"
  run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *voxel-cp-abc* && "$output" == *voxel-cp-def* ]]
  refute_called 'config set image.cp'
}

@test "isolated mode sets mode and uplink" {
  VOXEL_EXTERNAL_MODE=isolated VOXEL_EXTERNAL_UPLINK=igb0 run "$STEP"
  [ "$status" -eq 0 ]
  assert_called '^voxel config set external.mode isolated$'
  assert_called '^voxel config set external.uplink igb0$'
}

@test "lan mode sets no uplink" {
  run "$STEP"
  refute_called 'external.uplink'
}

@test "isolated without an uplink exits 1" {
  VOXEL_EXTERNAL_MODE=isolated run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VOXEL_EXTERNAL_UPLINK is required in isolated mode"* ]]
}
```

- [ ] **Step 3: Run them to make sure they fail**

Run: `bats test/step-voxel-conf.bats`
Expected: the new tests FAIL.

- [ ] **Step 4: Implement.** Before the arrays: `cp_image()` returns `VOXEL_CP_IMAGE` when set, else the basenames of `zfs list -H -o name -r <dataset>/img` that match `^voxel-cp-`; zero lines logs the step 80 message and `exit 1`; two or more logs `more than one voxel-cp image under <dataset>/img: <names>; set VOXEL_CP_IMAGE` and `exit 1`. The mode check exits 1 with the exact message when isolated and the uplink is empty. Then append `image.cp`, `image.frr`, `external.mode` to the arrays, and `external.uplink` only in isolated mode. The dataset is `${FALCON_DATASET:-rpool/falcon}`.

- [ ] **Step 5: Run the tests, lint, commit**

Run: `bats test/step-voxel-conf.bats && test/lint.sh`

```bash
git add -A host/70-voxel-conf.sh host/85-voxel-conf.sh test/step-voxel-conf.bats
git commit -m "Step 85: voxel.toml gets the images and the external mode, after the image build"
```

---

### Task 4: step 87, the propolis binary

**Files:**
- Create: `host/87-propolis.sh`
- Test: `test/step-propolis.bats`

**Interfaces:**
- Produces: `/opt/homicron/propolis/<rev>` (0755) and `<rev>.sha256` beside it; `falcon.propolis_binary` set to that path. Path override `HOMICRON_PROPOLIS_DIR` (default `/opt/homicron/propolis`).

- [ ] **Step 1: Write the failing tests.** Setup: fakes `su` and `voxel` as in `test/step-voxel-conf.bats`; `export HOMICRON_PROPOLIS_DIR="$BATS_TEST_TMPDIR/propolis"`; a `Cargo.toml` at `$SRC/Cargo.toml` with the line `propolis-client = { git = "https://github.com/oxidecomputer/propolis", rev = "5e201ec4185ccb9182cc6ffcb09fadd9deee24ca" }`; `make_fake curl` whose script writes `$BATS_TEST_TMPDIR/body` to the `-o` target when the URL ends in `propolis-server`, and prints `$BATS_TEST_TMPDIR/digest` when it ends in `.sha256.txt`; `make_fake digest` printing the sha256 of its last argument (`shasum -a 256 "${*: -1}" | cut -d" " -f1` on the Mac; `digest -a sha256 FILE` is the illumos form the step calls). Fixture: `body` holds `binary`, `digest` holds its sha256.

```bash
REV=5e201ec4185ccb9182cc6ffcb09fadd9deee24ca
URL=https://buildomat.eng.oxide.computer/public/file/oxidecomputer/propolis/falcon/$REV/propolis-server

@test "downloads the digest then the binary with retries, installs, and sets the key" {
  run "$STEP"
  [ "$status" -eq 0 ]
  assert_called "^curl -fsSL --retry 5 --retry-all-errors $URL.sha256.txt$"
  assert_called "^curl -fsSL --retry 5 --retry-all-errors -C - -o $HOMICRON_PROPOLIS_DIR/$REV.part $URL$"
  [ -x "$HOMICRON_PROPOLIS_DIR/$REV" ]
  [ -f "$HOMICRON_PROPOLIS_DIR/$REV.sha256" ]
  assert_called "^voxel config set falcon.propolis_binary $HOMICRON_PROPOLIS_DIR/$REV$"
}

@test "a matching binary and key skip the download" {
  run "$STEP"; : > "$FAKE_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute_called '^curl'
}

@test "a digest mismatch deletes the part file and exits 1 with both digests" {
  echo 0000000000000000000000000000000000000000000000000000000000000000 > "$BATS_TEST_TMPDIR/digest"
  run "$STEP"
  [ "$status" -eq 1 ]
  [ ! -e "$HOMICRON_PROPOLIS_DIR/$REV.part" ]
  [ ! -e "$HOMICRON_PROPOLIS_DIR/$REV" ]
  [[ "$output" == *0000000000000000* ]]
}

@test "a Cargo.toml without the rev exits 1" {
  : > "$SRC/Cargo.toml"
  run "$STEP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read the propolis rev from voxel's Cargo.toml"* ]]
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bats test/step-propolis.bats`
Expected: FAIL, the step file does not exist.

- [ ] **Step 3: Write `host/87-propolis.sh`.** `rev()` greps `^propolis-client *=.*rev *= *"([0-9a-f]{40})"` from `$src/Cargo.toml`. `check`: binary exists and is executable, `digest -a sha256 <binary>` equals the saved `.sha256`, and `config get falcon.propolis_binary` (quotes stripped as step 85 does) equals the path. `apply`: `mkdir -p`, fetch the digest to a variable, fetch the binary to `<rev>.part`, compare `digest -a sha256` of the part file, on mismatch `rm -f` the part and `log` both digests and `exit 1`, else `mv`, `chmod 0755`, save the digest file, set the key.

- [ ] **Step 4: Run the tests, lint, commit**

Run: `bats test/step-propolis.bats && test/lint.sh`

```bash
git add host/87-propolis.sh test/step-propolis.bats
git commit -m "Step 87: propolis-server from buildomat, digest checked, outside the falcon workspace"
```

---

### Task 5: the service files

**Files:**
- Create: `host/voxel-rack.xml`, `host/voxel-rack-start.sh`, `host/voxel-rack-stop.sh`
- Test: `test/voxel-rack.bats`

**Interfaces:**
- Consumes: `/opt/homicron/host.env` (`HOMICRON_USER`); overrides `HOMICRON_DIR`, `HOMICRON_HOME`, `HOMICRON_RACK_LOG` (default `/var/log/voxel-rack.log`).
- Produces: the three files Task 6 installs; the manifest names `/opt/homicron/voxel-rack-start.sh` and `/opt/homicron/voxel-rack-stop.sh`.

- [ ] **Step 1: Write the failing tests.** Setup: fakes `su` (as in the step tests) and `pfexec` (runs its arguments); a fake `voxel` at `$SRC/target/release/voxel` whose `destroy` logs itself, whose `launch` prints the content of `$BATS_TEST_TMPDIR/launch-out` (default two lines: `rack-init: complete, rack initialized` and `launch complete`); `export HOMICRON_DIR="$BATS_TEST_TMPDIR/opt"` holding `host.env` with `HOMICRON_USER=vmuser`; `HOMICRON_HOME`; `HOMICRON_RACK_LOG="$BATS_TEST_TMPDIR/rack.log"`; `CONFIG="$HOMICRON_HOME/vmuser/.config/voxel"` created.

```bash
@test "manifest is well-formed xml and names the two methods and the apply dependency" {
  run xmllint --noout "$HOST/voxel-rack.xml"
  [ "$status" -eq 0 ]
  grep -q "exec='/opt/homicron/voxel-rack-start.sh'" "$HOST/voxel-rack.xml"
  grep -q "exec='/opt/homicron/voxel-rack-stop.sh'" "$HOST/voxel-rack.xml"
  grep -q "svc:/site/homicron-apply:default" "$HOST/voxel-rack.xml"
  grep -q "timeout_seconds='2400'" "$HOST/voxel-rack.xml"
  grep -q "enabled='false'" "$HOST/voxel-rack.xml"
}

@test "start: no workspace, launch ok: no destroy, launch as the user, exit 0, header in the log" {
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 0 ]
  refute_called 'voxel destroy'
  assert_called '^su - vmuser -c pfexec .*voxel launch$'
  grep -q '^=== start ' "$HOMICRON_RACK_LOG"
  grep -q 'launch complete' "$HOMICRON_RACK_LOG"
}

@test "start: a workspace is destroyed first" {
  mkdir -p "$CONFIG/.falcon"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 0 ]
  [[ "$(fake_calls | grep -o 'voxel \(destroy\|launch\)' | tr '\n' '|')" == 'voxel destroy|voxel launch|' ]]
  grep -q 'destroying the previous rack' "$HOMICRON_RACK_LOG"
}

@test "start: rack-init FAILED exits 95 even when launch complete follows" {
  printf 'rack-init FAILED: Bootstore error\nlaunch complete\n' > "$BATS_TEST_TMPDIR/launch-out"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 95 ]
  grep -q 'launch failed; see above' "$HOMICRON_RACK_LOG"
}

@test "start: missing launch complete exits 95" {
  : > "$BATS_TEST_TMPDIR/launch-out"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 95 ]
}

@test "start: missing host.env exits 96" {
  rm "$HOMICRON_DIR/host.env"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 96 ]
}

@test "start: the hook runs as the user after success, and its failure keeps exit 0" {
  printf '#!/bin/bash\necho hook ran; exit 3\n' > "$CONFIG/post-launch.sh"; chmod +x "$CONFIG/post-launch.sh"
  run "$HOST/voxel-rack-start.sh"
  [ "$status" -eq 0 ]
  grep -q 'hook ran' "$HOMICRON_RACK_LOG"
  grep -q 'post-launch.sh exited 3' "$HOMICRON_RACK_LOG"
  assert_called '^su - vmuser -c .*post-launch.sh'
}

@test "start: a hook that is not executable, or a failed launch, does not run it" {
  printf 'echo hook ran\n' > "$CONFIG/post-launch.sh"
  run "$HOST/voxel-rack-start.sh"
  ! grep -q 'hook ran' "$HOMICRON_RACK_LOG"
}

@test "stop: destroys when the workspace exists, exits 0 either way" {
  run "$HOST/voxel-rack-stop.sh"
  [ "$status" -eq 0 ]
  refute_called 'voxel destroy'
  mkdir -p "$CONFIG/.falcon"
  run "$HOST/voxel-rack-stop.sh"
  [ "$status" -eq 0 ]
  assert_called '^su - vmuser -c pfexec .*voxel destroy$'
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bats test/voxel-rack.bats`
Expected: FAIL, the files do not exist.

- [ ] **Step 3: Write `host/voxel-rack.xml`** from `host/homicron-apply.xml`: service `site/voxel-rack`, `enabled='false'`, `single_instance`, dependencies `multi-user-server` and `homicron-apply` (both `require_all`, `restart_on='none'`), start `/opt/homicron/voxel-rack-start.sh` timeout 2400, stop `/opt/homicron/voxel-rack-stop.sh` timeout 600, `startd/duration transient`, common name `voxel rack: destroy and relaunch at boot`.

- [ ] **Step 4: Write `host/voxel-rack-start.sh`.** `set -o nounset -o pipefail`, no errexit. Variables as in `apply.sh` (`dir`, the log path override). Missing `host.env` writes `host.env missing in <dir>; no launch` to the log and exits 96. Source it with `allexport`. `voxel`, `config="$home_root/$HOMICRON_USER/.config/voxel"`. `run_voxel ARGS` is `su - "$HOMICRON_USER" -c "pfexec $voxel ARGS" < /dev/null >> "$log" 2>&1`. Steps as the spec lists: header, destroy when `$config/.falcon` exists (log the destroy line, ignore its status), launch into a temporary capture appended to the log, success is `grep -q 'launch complete'` and not `grep -q 'rack-init FAILED'` on the capture, failure logs `launch failed; see above` and exits 95, the hook runs as `su - "$HOMICRON_USER" -c "$config/post-launch.sh"` when `-x` and its status is logged as `post-launch.sh exited <N>`, exit 0.

- [ ] **Step 5: Write `host/voxel-rack-stop.sh`**: same preamble, destroy through `run_voxel` when `.falcon` exists, exit 0.

- [ ] **Step 6: Run the tests, lint, commit**

Run: `bats test/voxel-rack.bats && test/lint.sh`

```bash
git add host/voxel-rack.xml host/voxel-rack-start.sh host/voxel-rack-stop.sh test/voxel-rack.bats
git commit -m "Rack service: destroy and relaunch under svc:/site/voxel-rack, after homicron-apply"
```

---

### Task 6: step 90, install the service

**Files:**
- Create: `host/90-voxel-rack.sh`
- Test: `test/step-voxel-rack.bats`

**Interfaces:**
- Consumes: the three files from Task 5 in `$HOMICRON_DIR` (default `/opt/homicron`), `VOXEL_RACK`.
- Produces: `/lib/svc/manifest/site/voxel-rack.xml` (override `HOMICRON_MANIFEST_DIR`), the service imported, enabled or disabled.

- [ ] **Step 1: Write the failing tests.** Setup as in `test/start-apply.bats`: `HOMICRON_DIR` holding copies of the three files, fakes `svccfg`, `svcadm`, and `svcs` answering from a `$STATES` file (default `disabled`), `VOXEL_RACK=yes`. The step runs from `$HOMICRON_DIR`, so `lib.sh` must be copied there too.

```bash
@test "validates, installs, imports, and enables" {
  run "$HOMICRON_DIR/90-voxel-rack.sh"
  [ "$status" -eq 0 ]
  assert_called "^svccfg validate $HOMICRON_DIR/voxel-rack.xml$"
  cmp -s "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/voxel-rack.xml"
  assert_called "^svccfg import $HOMICRON_MANIFEST_DIR/voxel-rack.xml$"
  assert_called '^svcadm enable site/voxel-rack$'
  [[ "$output" == *"voxel-rack enabled; the launch runs under svc:/site/voxel-rack, log /var/log/voxel-rack.log"* ]]
}

@test "a validation failure changes nothing and exits 1" {
  printf 'echo bad >&2; exit 1\n' > "$FAKE_BIN/svccfg.script"
  run "$HOMICRON_DIR/90-voxel-rack.sh"
  [ "$status" -eq 1 ]
  [ ! -e "$HOMICRON_MANIFEST_DIR/voxel-rack.xml" ]
  refute_called '^svcadm'
}

@test "VOXEL_RACK=no disables" {
  echo online > "$STATES"
  VOXEL_RACK=no run "$HOMICRON_DIR/90-voxel-rack.sh"
  [ "$status" -eq 0 ]
  assert_called '^svcadm disable site/voxel-rack$'
}

@test "already installed and enabled: nothing runs" {
  cp "$HOMICRON_DIR/voxel-rack.xml" "$HOMICRON_MANIFEST_DIR/"
  echo online > "$STATES"
  run "$HOMICRON_DIR/90-voxel-rack.sh"
  [ "$status" -eq 0 ]
  refute_called '^svcadm'
  refute_called '^svccfg'
}

@test "a changed manifest is validated, copied, and imported without touching an enabled service" {
  echo '<!-- old -->' > "$HOMICRON_MANIFEST_DIR/voxel-rack.xml"
  echo online > "$STATES"
  run "$HOMICRON_DIR/90-voxel-rack.sh"
  [ "$status" -eq 0 ]
  assert_called '^svccfg import'
  refute_called '^svcadm'
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bats test/step-voxel-rack.bats`

- [ ] **Step 3: Write `host/90-voxel-rack.sh`.** `enabled()` reads `svcs -H -o state` and maps `online`, `offline`, `offline*` to enabled and `disabled`, `maintenance`, missing to not enabled; `want` is `VOXEL_RACK == yes`. `check`: the installed manifest `cmp`s the shipped one, the state is not `missing`, and `enabled` equals `want`. `apply`: `svccfg validate` (on failure print its output and `exit 1`), `mkdir -p`, `cp`, `svccfg import`, then `svcadm enable` or `svcadm disable` when `enabled` differs from `want`, and the log line. Because `check` compares files and state only, a re-run on a converged box skips the import, which keeps `apply` cheap; a changed manifest or method file fails `cmp` and triggers the import.

Note for the implementer: the method scripts are already in `/opt/homicron` because the runner rsyncs all of `host/`; the step installs only the manifest. The `cmp` in `check` therefore covers the manifest alone, and a method change ships with the rsync.

- [ ] **Step 4: Run the tests, lint, commit**

Run: `bats test/step-voxel-rack.bats && test/lint.sh`

```bash
git add host/90-voxel-rack.sh test/step-voxel-rack.bats
git commit -m "Step 90: install and enable the rack service"
```

---

### Task 7: documentation

**Files:**
- Modify: `README.md` ("Install a machine" step 6 paragraph, "What the stages do" table row for `host/NN-*.sh`, the service paragraph near line 116, "Known issue" unchanged)
- Modify: `hosts/README.md` (done in Task 1; re-read for consistency)

- [ ] **Step 1: README "Install a machine".** After the step 6 paragraph, add a paragraph: when `apply complete` prints, the rack launches under `svc:/site/voxel-rack` (about ten minutes) and relaunches, empty, after every boot. The console is `https://recovery.sys.rack1.oxide.test`, HTTPS with a self-signed certificate that voxel supplies, login `recovery`, password `oxide`. The workstation route and hosts entry, in a code block:

```
sudo route add -net 198.51.100.0/24 <host-address>
dig +short @198.51.100.20 recovery.sys.rack1.oxide.test A   # pick one address
printf '<nexus-address> recovery.sys.rack1.oxide.test\n' | sudo tee -a /etc/hosts
```

Then: `svcs -xv site/voxel-rack` and `/var/log/voxel-rack.log` on failure, `svcadm disable` destroys the rack, `svcadm restart` rebuilds it, and `pfexec voxel destroy` by hand leaves the service online with no rack. Then the hook: `~/.config/voxel/post-launch.sh`, executable, runs as your login after each launch, with a two-line example (`oxide auth login --host https://recovery.sys.rack1.oxide.test` is interactive, so the example uses `oxide --host … project create --name lab --description "created by post-launch.sh"` with a note that the CLI needs a token, see the Oxide docs).

- [ ] **Step 2: README "What the stages do".** Extend the `host/NN-*.sh` row with `the network layout and chrony`, `the voxel.toml keys`, `the propolis binary`, `the rack service`. Extend the service paragraph with one sentence naming `host/voxel-rack.xml`, `voxel-rack-start.sh`, and `voxel-rack-stop.sh`, and that the rack service waits for `site/homicron-apply` to be online.

- [ ] **Step 3: Check the plain-English rules** on the new text: sentences under 25 words, no contractions, no semicolons, condition before command.

- [ ] **Step 4: Commit**

```bash
git add README.md hosts/README.md
git commit -m "Docs: the rack at boot, the console address, the hook"
```

---

### Task 8: apply to homicron00 and the reboot test

**Files:** none in the repository. `hosts/homicron00.env` (gitignored) gains:

```
VOXEL_EXTERNAL_MODE=isolated
VOXEL_EXTERNAL_UPLINK=igb0
MGMT_LINKS=igb1
```

- [ ] **Step 1: Full test run**

Run: `test/lint.sh && test/run-tests.sh`
Expected: exit 0.

- [ ] **Step 2: Apply.** `HOMICRON_ADDR=192.168.0.154 bin/homicron apply homicron00`. Expected in the stream: steps 10 to 80 `already in the desired state`; step 25 finds the dhcpagent line and chrony online; step 85 sets nothing new except that the existing `image.cp` matches; step 87 downloads the rev to `/opt/homicron/propolis/` and repoints `falcon.propolis_binary`; step 90 prints `voxel-rack enabled…`; `apply complete`.

- [ ] **Step 3: Watch the service.** On the box: `svcs -xv site/voxel-rack` shows `offline*` during the launch and `online` after about ten minutes; `tail -f /var/log/voxel-rack.log` ends with `launch complete`. Then from the Mac: `curl -k -sS https://recovery.sys.rack1.oxide.test/v1/ping` prints `{"status":"ok"}`.

- [ ] **Step 4: Reboot test.** `ssh jacob@192.168.0.154 'pfexec reboot'`. About twelve minutes later: `svcs site/homicron-apply site/voxel-rack` shows both `online`, the log shows a new `=== start` header, `destroying the previous rack`, and `launch complete`, and the ping from the Mac succeeds (the hosts entry may need the new Nexus address from `dig`).

- [ ] **Step 5: Clean up and record.** Delete `~/bin/propolis-server-5e201ec4…` on the box. Update the memory file `homicron-first-install.md` under `~/.claude/projects/-Users-jacob-Code-jacobthemyth-homicron/memory/` with the service name, the log path, and the reboot result.
