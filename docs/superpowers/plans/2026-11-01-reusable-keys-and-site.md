# Reusable Keys and Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every assumption that ties homicron to one person's keys, one workstation, and one published site. Anyone can then install a machine from the published site or from a fork with no edit to the code.

**Architecture:** The installer takes the trusted keys from a URL the person types. The runner takes them from the workstation's `~/.ssh/*.pub` or from a runner-only `HOMICRON_KEYS` value, and defaults the login and uid to the workstation's. One key line rule, written in both scripts, refuses a file that is not an `authorized_keys` file. The site build substitutes its own address and repository link, and the workflow supplies both from GitHub. The repository carries no key and no `CNAME`.

**Tech Stack:** bash, bats-core, shellcheck, GitHub Actions (`actions/configure-pages@v5`, `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4`), qemu-system-x86_64 with KVM. Illumos tools on the target: `install-helios`, `diskinfo`, `svccfg`.

**Spec:** `docs/superpowers/specs/2026-11-01-reusable-keys-and-site-design.md`

## Global Constraints

- Every script starts with `#!/bin/bash`. Target scripts must run on Helios `/bin/bash`. Workstation scripts must run on macOS `/bin/bash` 3.2 and on Linux.
- `install/install.sh` is served alone, so it has no `source` line. The key line rule is written once in `install/install.sh` and once in `bin/homicron`, with the same function names and the same regexes.
- The key line rule: a line is blank, a comment (optional whitespace then `#`), or a key line. A key line has a field matching `^(sk-)?(ssh|ecdsa)-[A-Za-z0-9.@-]+$` followed by a field matching `^[A-Za-z0-9+/=]+$`. A file with no key line is refused. A file with a line that is none of the three is refused with its line number.
- Exit codes: 0 success, 2 usage or configuration error, 1 any other failure. The installer exits 1 for a fetch failure or a refused keys file, 2 for a missing `HOMICRON_KEYS_URL`. The runner exits 2 for every keys problem, because they all happen before rsync.
- Tests fake target commands by prepending `$FAKE_BIN` to `PATH` with `make_fake` from `test/helpers/fakes.bash`. No test runs a real `ssh`, `rsync`, `curl`, or `qemu`.
- `test/lint.sh` and `test/run-tests.sh` pass at every commit. Run both before each commit step.
- One commit per task. The message names the component and the change.
- Prose in README, hosts/README, and script comments follows the writing rules already in those files: short sentences, no contractions, no semicolons. The word laptop does not appear outside `docs/superpowers/`.
- Three places in the code name this instance of the project: the `base_url=` default in `install/install.sh`, and the two default lines in `pages/build-site.sh`. The README names it too.

## Review Focus

1. `~/.ssh/` on the workstation can hold `id_ed25519-cert.pub`. A certificate line passes the key line rule but is not a key sshd accepts in `authorized_keys`. The default glob must skip `*-cert.pub`. Pinned in Task 2.
2. `HOMICRON_KEYS` can name a directory or an unreadable file. The runner must exit 2 with the path in the message, before rsync. Pinned in Task 2.
3. A fetched keys file can lack a trailing newline. Its last key must still count and must still be seeded. Pinned in Task 1.
4. `apply` run as root makes `id -un` return `root` and `id -u` return `0`. Step 10 then runs `useradd -u 0`. When the resolved login is `root` or the resolved uid is `0`, the runner must exit 2. Pinned in Task 3.
5. A hosts file can set `HOMICRON_KEYS=` to an empty value, which the syntax rule allows. The runner must treat it as unset and use the default. Pinned in Task 2.

---

### Task 1: Installer: keys from `HOMICRON_KEYS_URL`

**Files:**
- Modify: `install/install.sh:1-30` (header, variables, usage), `install/install.sh:66-96` (files array, fetch, keys guard), `install/install.sh:131-132` (`homicron.conf`)
- Modify: `test/helpers/fake_site.bash`
- Modify: `test/install.bats`
- Modify: `test/firstboot.bats:8`

**Interfaces:**
- Produces: `check_keys_file FILE` in `install/install.sh`. For each bad line it prints `install: keys: line N is not a public key` to stderr and returns 1. For a file with no key line it returns 1 with no output. Otherwise it returns 0. `is_key_line LINE` returns 0 for a key line. Task 2 copies both into `bin/homicron` with the `homicron:` prefix.
- Produces: a fake curl that serves `$FAKE_KEYS` for the URL `$HOMICRON_KEYS_URL`.

- [ ] **Step 1: Update the fake site helper**

In `test/helpers/fake_site.bash`, remove the `keys` directory from `fake_site_setup` and `fake_site_resum` (`mkdir -p "$dir/firstboot"`, `_sum_tool firstboot/* > SHA256SUMS`, no `cp` of keys). In the curl script, before the `rel=` line, add:

```bash
if [[ -n ${HOMICRON_KEYS_URL:-} && $url == "$HOMICRON_KEYS_URL" ]]; then
  src="$FAKE_KEYS"
else
  rel="${url#"$HOMICRON_BASE_URL"/}"
  src="$FAKE_SITE/$rel"
fi
```

Update the header comment: the helper serves the site files and, at `$HOMICRON_KEYS_URL`, the file `$FAKE_KEYS`.

- [ ] **Step 2: Rewrite the install tests**

In `setup()` of `test/install.bats` add:

```bash
export HOMICRON_KEYS_URL=https://keys.test/user.keys FAKE_KEYS="$BATS_TEST_TMPDIR/user.keys"
printf 'ssh-ed25519 AAAA test\n' > "$FAKE_KEYS"
```

Change the four existing keys tests (`sk-` key, indented key, comment-only, empty) to write `$FAKE_KEYS` and drop their `fake_site_resum` call. In the happy path test, compare root's `authorized_keys` with `$FAKE_KEYS`, replace the `BASE_URL=http://site.test` assertion with `grep -qx 'KEYS_URL=https://keys.test/user.keys'`, and add `! grep -q '^BASE_URL=' "$HOMICRON_ALTROOT/etc/homicron.conf"`. Add:

```bash
@test "no HOMICRON_KEYS_URL exits 2 with usage before any fetch" {
  unset HOMICRON_KEYS_URL
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOMICRON_KEYS_URL"* ]]
  [[ "$output" == *"github.com/<user>.keys"* ]]
  refute_called '^curl'
  refute_called '^install-helios'
}

@test "a keys URL that cannot be fetched exits 1 with the URL" {
  rm "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://keys.test/user.keys"* ]]
  refute_called '^install-helios'
}

@test "a keys file with a line that is not a key exits 1 with the line number" {
  printf 'ssh-ed25519 AAAA ok\n<html><body>Not Found</body></html>\n' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 2 is not a public key"* ]]
  refute_called '^install-helios'
}

@test "an option-prefixed key line counts as a key" {
  printf 'from="10.0.0.0/8",no-pty ssh-rsa AAAAB3 lab\n' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  assert_called '^install-helios'
}

@test "a keys file without a trailing newline keeps its last key" {
  printf 'ssh-ed25519 AAAA one\nssh-ed25519 BBBB two' > "$FAKE_KEYS"
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  grep -q 'BBBB two' "$HOMICRON_ALTROOT/root/.ssh/authorized_keys"
}

@test "the site keys path is never fetched" {
  run "$SCRIPT" host01 c1t0d0
  [ "$status" -eq 0 ]
  refute_called 'keys/authorized_keys'
}
```

In `test/firstboot.bats:8` change `BASE_URL=https://homicron.smithjs.org` to `KEYS_URL=https://github.com/user.keys`.

- [ ] **Step 3: Run the tests to make sure that they fail**

Run: `bats test/install.bats`
Expected: the six new tests and the happy path FAIL. The `sk-`, indented, comment-only, and empty tests FAIL because the installer still reads the site file.

- [ ] **Step 4: Implement**

In `install/install.sh`:

- Add `keys_url=${HOMICRON_KEYS_URL:-}` beside `base_url`.
- Extend `usage()` with two lines: `  HOMICRON_KEYS_URL=<url> is required: a URL that serves your public keys, one per line` and `  for example https://github.com/<user>.keys`. In section 2, before the argument count check, `[[ -n $keys_url ]] || usage`.
- Add `is_key_line` and `check_keys_file` after `sum_of`, per the Interfaces block. Use `read -r -a` to split the line and two regex variables, `type_re` and `blob_re`, with the patterns from Global Constraints.
- Remove `keys/authorized_keys` from `files`.
- After the site loop, `printf 'fetching keys from %s\n' "$keys_url"` and `curl -fsSL -o "$tmp/authorized_keys" "$keys_url" || fail "could not fetch keys from $keys_url"`. Replace the `grep -Eq` guard with `check_keys_file "$tmp/authorized_keys" || fail "$keys_url holds no usable key; refusing to install a machine nobody can log in to"`.
- Seed from `$tmp/authorized_keys`.
- Write `HOSTNAME=%s\nKEYS_URL=%s\n` to `homicron.conf`.
- Update the header comment to the typed line in the spec, with `<nic>` and `HOMICRON_KEYS_URL`.

- [ ] **Step 5: Run the tests and lint**

Run: `bats test/install.bats test/firstboot.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add install/install.sh test/install.bats test/firstboot.bats test/helpers/fake_site.bash
git commit -m "Installer: keys come from HOMICRON_KEYS_URL, every line must be a key"
```

---

### Task 2: Runner: `HOMICRON_KEYS` and the workstation default

**Files:**
- Modify: `bin/homicron:1-30` (header, `host_vars`), `bin/homicron:52-66` (`known_var`), `bin/homicron:200-230` (`apply`)
- Modify: `test/homicron.bats`

**Interfaces:**
- Consumes: `is_key_line` and `check_keys_file` from Task 1, copied with the `homicron: keys: line N is not a public key` message.
- Produces: `runner_vars=(HOMICRON_KEYS)` in `bin/homicron`. `collect_keys OUT` writes the keys file to `OUT` or dies with exit 2. `apply` ships `$tmp/host.env` and `$tmp/authorized_keys` from one `mktemp -d` directory.

- [ ] **Step 1: Update the runner tests**

In `setup()` of `test/homicron.bats`, delete `: > "$REPO/keys/authorized_keys"` and the `keys` entry in `mkdir -p`. Add:

```bash
export HOME="$BATS_TEST_TMPDIR/home"
mkdir -p "$HOME/.ssh"
printf 'ssh-ed25519 AAAA workstation\n' > "$HOME/.ssh/id_ed25519.pub"
unset HOMICRON_KEYS
```

Add a helper after `setup()` that the key tests share:

```bash
capture_sent() {
  cat > "$FAKE_BIN/rsync.script" <<'EOS'
dest="${*: -1}"; src="${*: -2:1}"
case "$dest" in *host.env) cp "$src" "$BATS_TEST_TMPDIR/sent.env" ;; *authorized_keys) cp "$src" "$BATS_TEST_TMPDIR/sent.keys" ;; esac
exit 0
EOS
}
```

Use it in "sends a resolved host.env" in place of its inline rsync script, and change line 176 to `grep -qx 'HOMICRON_USER=vmuser'`. Add:

```bash
@test "by default the shipped keys are every ~/.ssh/*.pub, each ending in a newline, certificates skipped" {
  printf 'ssh-rsa BBBB second' > "$HOME/.ssh/id_rsa.pub"
  printf 'ssh-ed25519-cert-v01@openssh.com CCCC cert\n' > "$HOME/.ssh/id_ed25519-cert.pub"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/sent.keys" | tr -d ' ')" -eq 2 ]
  grep -qx 'ssh-ed25519 AAAA workstation' "$BATS_TEST_TMPDIR/sent.keys"
  grep -qx 'ssh-rsa BBBB second' "$BATS_TEST_TMPDIR/sent.keys"
  ! grep -q CCCC "$BATS_TEST_TMPDIR/sent.keys"
}

@test "no ~/.ssh/*.pub and no HOMICRON_KEYS exits 2 before rsync" {
  rm "$HOME/.ssh/id_ed25519.pub"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *'~/.ssh/*.pub'* ]]
  [[ "$output" == *"HOMICRON_KEYS"* ]]
  refute_called '^rsync'
}

@test "HOMICRON_KEYS as a path ships that file" {
  printf 'ssh-ed25519 DDDD shared\n' > "$BATS_TEST_TMPDIR/shared.keys"
  printf 'HOMICRON_KEYS=%s\n' "$BATS_TEST_TMPDIR/shared.keys" >> "$REPO/hosts/box.env"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/sent.keys" "$BATS_TEST_TMPDIR/shared.keys"
  ! grep -q '^HOMICRON_KEYS=' "$BATS_TEST_TMPDIR/sent.env"
}

@test "HOMICRON_KEYS as a URL is fetched with curl and shipped" {
  make_fake curl 0 'ssh-ed25519 EEEE fetched'
  capture_sent
  HOMICRON_KEYS=https://github.com/user.keys run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  assert_called '^curl .*https://github.com/user.keys$'
  grep -qx 'ssh-ed25519 EEEE fetched' "$BATS_TEST_TMPDIR/sent.keys"
}

@test "a keys URL that cannot be fetched exits 2 before rsync" {
  make_fake curl 22
  HOMICRON_KEYS=https://github.com/user.keys run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"https://github.com/user.keys"* ]]
  refute_called '^rsync'
}

@test "HOMICRON_KEYS that is a directory or unreadable exits 2 with the path" {
  HOMICRON_KEYS="$BATS_TEST_TMPDIR" run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR"* ]]
  HOMICRON_KEYS="$BATS_TEST_TMPDIR/missing" run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  refute_called '^rsync'
}

@test "an empty HOMICRON_KEYS in the hosts file means the default" {
  printf 'HOMICRON_KEYS=\n' >> "$REPO/hosts/box.env"
  capture_sent
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 0 ]
  grep -qx 'ssh-ed25519 AAAA workstation' "$BATS_TEST_TMPDIR/sent.keys"
}

@test "a keys source with a line that is not a key exits 2 with the line number" {
  printf '<html>\n' >> "$HOME/.ssh/id_ed25519.pub"
  run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"line 2 is not a public key"* ]]
  refute_called '^rsync'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/homicron.bats`
Expected: the eight new tests FAIL. The rest PASS. The fake rsync does not read its source, so the missing `keys/authorized_keys` does not show here.

- [ ] **Step 3: Implement**

In `bin/homicron`:

- Header: `homicron: workstation-side runner.` Under the `<name>` paragraph add: `HOMICRON_KEYS names the public keys to install, as a URL or an absolute path. Unset, the runner ships every ~/.ssh/*.pub on this machine.`
- Add `runner_vars=(HOMICRON_KEYS)` after `host_vars`. Its comment says: accepted in the hosts file and the environment, never shipped in `host.env`. `known_var` returns 0 for a name in either array.
- Copy `is_key_line` and `check_keys_file` from Task 1 with the `homicron: keys:` prefix.
- Add `collect_keys OUT` with `local src=${HOMICRON_KEYS-}` and three branches:
  - `$src` matches `^https?://`: `curl -fsSL "$src" > "$out" || die "cannot fetch keys from $src" 2`.
  - `$src` is non-empty: `[[ -f $src && -r $src ]] || die "HOMICRON_KEYS: $src is not a readable file" 2`, then `cat "$src" > "$out"`.
  - `$src` is empty: `: > "$out"`, then loop over `"$HOME"/.ssh/*.pub`. Skip a name that is not a file and a name that matches `*-cert.pub`. For the rest, `awk 1 "$f" >> "$out"`. `awk 1` prints every line with a newline, so a file without a trailing newline cannot fuse with the next. If `$out` then has no key line, `die 'no public key in ~/.ssh/*.pub; set HOMICRON_KEYS to a URL or an absolute path' 2`.
  - After the branches: `check_keys_file "$out" || die "refusing to ship a keys file with a line that is not a key" 2`.
- In `apply`: `tmp=$(mktemp -d)`, trap `rm -rf`, `write_resolved_env "$tmp/host.env"`, `collect_keys "$tmp/authorized_keys"`, then rsync `host/`, `$tmp/host.env` as `host.env`, `$tmp/authorized_keys` as `authorized_keys`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/homicron.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron test/homicron.bats
git commit -m "Runner: ship the workstation's public keys or HOMICRON_KEYS, never a repo file"
```

---

### Task 3: Runner: login and uid default to the workstation

**Files:**
- Modify: `bin/homicron:80-96` (`load_host` defaults)
- Modify: `hosts/vm.env`
- Modify: `test/homicron.bats`

**Interfaces:**
- Produces: `HOMICRON_USER` defaults to `$(id -un)`, `HOMICRON_UID` to `$(id -u)`. When the resolved login is `root` or the resolved uid is `0`, `load_host` dies with exit 2.

- [ ] **Step 1: Write the failing tests**

Change the first test to "missing host file exits 2 before rsync" and delete its `bad.env` half. Add:

```bash
@test "login and uid default to the workstation's" {
  printf 'HOMICRON_PORT=2222\n' > "$REPO/hosts/plain.env"
  capture_sent
  run "$REPO/bin/homicron" apply plain
  [ "$status" -eq 0 ]
  grep -qx "HOMICRON_USER=$(id -un)" "$BATS_TEST_TMPDIR/sent.env"
  grep -qx "HOMICRON_UID=$(id -u)" "$BATS_TEST_TMPDIR/sent.env"
}

@test "a root login or uid 0 exits 2 before rsync" {
  HOMICRON_USER=root run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  [[ "$output" == *"root"* ]]
  HOMICRON_UID=0 run "$REPO/bin/homicron" apply box
  [ "$status" -eq 2 ]
  refute_called '^rsync'
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/homicron.bats`
Expected: both new tests FAIL.

- [ ] **Step 3: Implement**

In `load_host`, replace the two "is required" lines with `export HOMICRON_USER=${HOMICRON_USER:-$(id -un)}` and `export HOMICRON_UID=${HOMICRON_UID:-$(id -u)}`, then `[[ $HOMICRON_USER != root && $HOMICRON_UID != 0 ]] || die "HOMICRON_USER=$HOMICRON_USER uid $HOMICRON_UID: the runner logs in as root and will not create root; set HOMICRON_USER and HOMICRON_UID" 2`. Replace `hosts/vm.env` with the three lines from the spec: `HOMICRON_PORT=2222`, `SWAP_SIZE=4G`, `DUMP_SIZE=4G`.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/homicron.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron hosts/vm.env test/homicron.bats
git commit -m "Runner: login and uid default to the workstation, refuse root"
```

---

### Task 4: Runner: name the host key in the unreachable message

**Files:**
- Modify: `bin/homicron` (`sync_to_box` and `step_failed`)
- Modify: `test/homicron.bats`

**Interfaces:**
- Produces: one function `unreachable` that dies with exit 1 and the message `cannot reach $HOMICRON_ADDR: ssh exited 255 (the box is down, or its host key changed after a reinstall; try ssh root@$HOMICRON_ADDR by hand)`.

- [ ] **Step 1: Extend the two existing tests**

In "exit 255 reports unreachable and exits 1" and "rsync failing to connect reports unreachable", add `[[ "$output" == *"host key"* ]]` and `[[ "$output" == *"ssh root@box.local"* ]]`.

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/homicron.bats`
Expected: both FAIL on the new assertions.

- [ ] **Step 3: Implement**

Add `unreachable()` with the message above and call it from the two places that die with `cannot reach`. The reboot timeout message in `reboot_box` does not change.

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/homicron.bats && test/lint.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/homicron test/homicron.bats
git commit -m "Runner: unreachable message names the host key and the manual ssh"
```

---

### Task 5: Site: no keys, no CNAME, substituted addresses

**Files:**
- Modify: `pages/build-site.sh`
- Modify: `pages/index.html`
- Delete: `pages/CNAME`, `keys/authorized_keys`
- Modify: `test/site.bats`

**Interfaces:**
- Produces: `pages/build-site.sh [OUTDIR]` reads `HOMICRON_BASE_URL` (default `https://homicron.smithjs.org`) and `HOMICRON_REPO_URL` (default `https://github.com/jacobthemyth/homicron`). The served `install` has its `base_url=` default rewritten to `HOMICRON_BASE_URL`. `index.html` holds `{{BASE_URL}}` and `{{REPO_URL}}`, replaced at build. Task 6 relies on the two placeholders.

- [ ] **Step 1: Rewrite the site tests**

In "builds the expected layout", drop `keys/authorized_keys` and `CNAME` from the list and delete the `CNAME` content assertion. In "SHA256SUMS verifies", expect 4 lines. In the guard test, drop `keys` from the `cp -R` list. Replace "install is byte-identical" with:

```bash
@test "the served install equals the source apart from the base_url default" {
  HOMICRON_BASE_URL=http://example.test "$SCRIPT" "$OUT"
  grep -qx 'base_url=${HOMICRON_BASE_URL:-http://example.test}' "$OUT/install"
  cmp <(grep -v '^base_url=' "$OUT/install") <(grep -v '^base_url=' "$BATS_TEST_DIRNAME/../install/install.sh")
  grep -q 'HOMICRON_BASE_URL:-https://homicron.smithjs.org}' "$BATS_TEST_DIRNAME/../install/install.sh"
}

@test "without HOMICRON_BASE_URL the served install keeps the source default" {
  "$SCRIPT" "$OUT"
  cmp "$OUT/install" "$BATS_TEST_DIRNAME/../install/install.sh"
}

@test "index.html gets the base URL and the repository URL" {
  HOMICRON_BASE_URL=http://example.test HOMICRON_REPO_URL=https://example.test/o/r "$SCRIPT" "$OUT"
  grep -q 'http://example.test/install' "$OUT/index.html"
  grep -q 'https://example.test/o/r' "$OUT/index.html"
  ! grep -q '{{' "$OUT/index.html"
}
```

- [ ] **Step 2: Run the tests to make sure that they fail**

Run: `bats test/site.bats`
Expected: the three new tests FAIL. The sums test FAILS because `SHA256SUMS` still has five lines.

- [ ] **Step 3: Implement**

- `git rm pages/CNAME keys/authorized_keys`.
- In `pages/build-site.sh`: add `base_url=${HOMICRON_BASE_URL:-https://homicron.smithjs.org}` and `repo_url=${HOMICRON_REPO_URL:-https://github.com/jacobthemyth/homicron}` under `out=`. Drop the `keys` directory, the keys `cp`, and `keys/authorized_keys` from the sum line. Replace the `cp` of `install.sh` with `sed -e "s|^base_url=\${HOMICRON_BASE_URL:-.*}\$|base_url=\${HOMICRON_BASE_URL:-$base_url}|" "$root/install/install.sh" > "$out/install"`. Replace the `cp` of `index.html` with `sed -e "s|{{BASE_URL}}|$base_url|g" -e "s|{{REPO_URL}}|$repo_url|g" "$root/pages/index.html" > "$out/index.html"`. Copy only `.nojekyll` beside it. Update the header comment: the two variables and what they replace.
- In `pages/index.html`: replace both `https://homicron.smithjs.org` occurrences with `{{BASE_URL}}`. Replace the GitHub link `href` and text with `{{REPO_URL}}`. Replace `rge0` with `&lt;nic&gt;`. In the typed line, add `HOMICRON_KEYS_URL=https://github.com/&lt;user&gt;.keys ` before `bash /tmp/i`. Change "From a laptop" to "From your workstation". After the typed line add two sentences: `HOMICRON_KEYS_URL names the public keys root will accept. GitHub serves yours at that address.`

- [ ] **Step 4: Run the tests and lint**

Run: `bats test/site.bats test/install.bats && test/lint.sh`
Expected: all PASS. `test/install.bats` still passes because its fake site is independent of `build-site.sh`.

- [ ] **Step 5: Commit**

```bash
git add -A pages test/site.bats
git commit -m "Site: drop the keys and CNAME, substitute the base and repository URLs"
```

---

### Task 6: Workflow: configure-pages supplies the addresses

**Files:**
- Modify: `.github/workflows/pages.yml:17-43`

**Interfaces:**
- Consumes: `HOMICRON_BASE_URL` and `HOMICRON_REPO_URL` from Task 5.
- Produces: nothing other tasks use.

- [ ] **Step 1: Merge `build` and `deploy`**

Replace both jobs with one `deploy` job: `needs: lint`, the same `if`, the same `concurrency` block, `runs-on: ubuntu-latest`, `permissions` with `contents: read`, `pages: write`, `id-token: write`, the same `environment`. Its steps, in order:

1. `actions/checkout@v4`.
2. `actions/configure-pages@v5` with `id: pages`.
3. `run: pages/build-site.sh _site` with `env:` `HOMICRON_BASE_URL: ${{ steps.pages.outputs.base_url }}` and `HOMICRON_REPO_URL: ${{ github.server_url }}/${{ github.repository }}`.
4. `actions/upload-pages-artifact@v3` with `path: _site`.
5. `actions/deploy-pages@v4` with `id: deployment`.

- [ ] **Step 2: Make sure that the file parses**

Run: `ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); puts y["jobs"].keys.join(" ")' .github/workflows/pages.yml`
Expected: `lint deploy`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/pages.yml
git commit -m "Pages: one deploy job, configure-pages supplies the site and repository URLs"
```

After the push, make sure in the Actions log that the build step printed `site built in` and that `curl -fsSL https://homicron.smithjs.org/install | grep '^base_url='` shows `https://homicron.smithjs.org`.

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `hosts/README.md`

**Interfaces:**
- Produces: nothing other tasks use.

- [ ] **Step 1: README**

- Typed line in "Install a machine" step 3: `ipadm create-addr -T dhcp <nic>/v4 && echo "nameserver $(dhcpinfo -i <nic> DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i https://homicron.smithjs.org/install && HOMICRON_KEYS_URL=https://github.com/<user>.keys bash /tmp/i <hostname> <disk> [<disk> [<disk>]]`. Add one sentence to the paragraph under it: `HOMICRON_KEYS_URL` names the public keys root will accept, and GitHub serves an account's keys at `https://github.com/<user>.keys`.
- Step 5: "root accepts the keys the install line named" in place of the `keys/authorized_keys` clause.
- Step 6: after the `apply` command, add two sentences. `apply` ships the public keys of this workstation (`~/.ssh/*.pub`) to root and to the new login. A hosts file that sets `HOMICRON_KEYS` replaces that default, and the login and uid default to this workstation's. Keep the rsync and reboot sentences.
- The stages table, `install/install.sh` row: "seeds `/a` with the keys from `HOMICRON_KEYS_URL`".
- "Rehearse in a VM": add `HOMICRON_KEYS_URL=https://github.com/<user>.keys` before `HOMICRON_BASE_URL` in the typed line, and one sentence: the VM reaches GitHub through qemu's user-mode network.
- New section "Run your own copy" before "Development", with four numbered steps:
  1. Fork the repository.
  2. Enable Pages with the workflow build type: `gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow`.
  3. If you want a custom domain, point a DNS CNAME at `<owner>.github.io` and run `gh api -X PUT repos/<owner>/<repo>/pages -f cname=<domain> -F https_enforced=true`.
  4. Push to `main` and type the install line with your site address.

  One closing paragraph: the published site at `https://homicron.smithjs.org` works for anyone, because the install line names the keys. A fork is only needed to change the code.
- Replace every "laptop" with "workstation" or with "the machine that runs `apply`".

- [ ] **Step 2: hosts/README.md**

- `HOMICRON_USER` row: Required `no`, Default `the workstation login (id -un)`.
- `HOMICRON_UID` row: Required `no`, Default `the workstation uid (id -u)`, Meaning: Numeric uid for that login. Files that move between the two machines keep their numeric owner, so a matching uid keeps that owner readable on both sides.
- New row `HOMICRON_KEYS`: Required `no`, Default `every ~/.ssh/*.pub on the workstation`, Meaning: Public keys for root and the login, as a URL or an absolute path. Runner-only, never shipped to the host.
- After the table, a paragraph of three sentences. `apply` overwrites root's and the login's `authorized_keys` with the shipped file. Two workstations that both use the default remove each other's key on every run. A setup with more than one workstation points `HOMICRON_KEYS` at one shared URL, the same URL the install line used.
- A sentence that `<name>.local` needs an mDNS resolver on the workstation. macOS has one. Many Linux hosts get one from avahi or systemd-resolved.
- A sentence that git ignores `hosts/*.env`, so a hosts file is private by default, and that `vm.env` is the one tracked exception.
- The `vm.env` paragraph: the test VM takes the workstation login and uid.

- [ ] **Step 3: Make sure that no laptop remains**

Run: `grep -rn -i laptop --exclude-dir=.git --exclude-dir=docs .`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add README.md hosts/README.md
git commit -m "Docs: keys URL on the install line, workstation defaults, run your own copy"
```

---

### Task 8: Rehearsal on the Arch Linux host

**Files:** none changed. If a step needed a workaround, record it in the README's rehearsal section.

- [ ] **Step 1:** On the Arch host, in a clone at the branch head, run `test/serve.sh 8000` in one terminal and `test/qemu.sh install` in another. Delete `test/vm/disk.qcow2` first for a clean install.

- [ ] **Step 2:** At the installer prompt, run the typed line from the README with `vioif0`, `HOMICRON_BASE_URL=http://10.0.2.2:8000`, and `HOMICRON_KEYS_URL=https://github.com/<user>.keys`. Make sure that the output has `fetching keys from https://github.com/<user>.keys` and ends with `install complete`.

- [ ] **Step 3:** Before the reboot, run the line once more without `HOMICRON_KEYS_URL`. Make sure that it prints usage with `HOMICRON_KEYS_URL`, exits 2, and `install-helios` does not run.

- [ ] **Step 4:** `reboot`, quit qemu at the loader, `test/qemu.sh boot`. Make sure that `ssh -p 2222 root@<arch-host> cat /etc/homicron.conf` prints `HOSTNAME=vm` and `KEYS_URL=https://github.com/<user>.keys`.

- [ ] **Step 5:** From the workstation, `HOMICRON_ADDR=<arch-host> bin/homicron apply vm`. Make sure that `apply` ends with `apply complete`. Make sure that step 10 created the workstation login with the workstation uid: `ssh -p 2222 root@<arch-host> getent passwd $(id -un)`. Make sure that `HOMICRON_ADDR=<arch-host> bin/homicron ssh vm` logs in.

- [ ] **Step 6:** Run `apply` a second time. Make sure that every step logs `already in the desired state`.
