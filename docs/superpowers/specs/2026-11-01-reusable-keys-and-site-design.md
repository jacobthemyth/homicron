# Reusable keys and site

Date: 2026-11-01

homicron works today for one person and one published site. The repository
carries that person's public keys, and the installer seeds them into every
machine it installs. The site address is written into the installer, the
site, and the docs. This document removes those assumptions. After it,
another person can install a machine from the published site or from a
fork with no edit to the code. The design in
[2026-10-31-homicron-design.md](2026-10-31-homicron-design.md) and the
fixes in [2026-11-01-review-fixes-design.md](2026-11-01-review-fixes-design.md)
still hold. This document changes only the details named below.

## Goals

- The repository and the published site carry no public key. Each install
  names the keys it trusts.
- `bin/homicron apply` trusts keys from the machine that runs it, or from a
  source the hosts file names.
- A fork deploys its own site with no edit to the code.
- The docs name the machine that runs `apply` as the workstation, not the
  laptop, and say why each per-machine value exists.
- Every change is covered by a bats test or by the qemu rehearsal.

## Non-goals

- A key format other than `authorized_keys`.
- Removing a key from a machine by any means other than `apply` with a keys
  source that no longer lists it.
- Fixing the deferred findings in the review-fixes design. This change
  reaches two of them and fixes those: `hosts/vm.env` restates code
  defaults, and `/etc/homicron.conf` records a `BASE_URL` that nothing
  reads.

## The key line rule

Three places read an `authorized_keys` file: the installer, the runner, and
step 10. They share one rule. A line is blank, a comment, or a key line. A
comment starts with optional whitespace and `#`. A key line has a field that
matches `^(sk-)?(ssh|ecdsa)-[A-Za-z0-9.@-]+$` followed by a field that
matches `^[A-Za-z0-9+/=]+$`. Options before the key type, such as
`from="10.0.0.0/8"`, are allowed because the rule looks at any pair of
adjacent fields.

A file with no key line is refused, as today. A file with a line that is
not blank, not a comment, and not a key line is also refused, with its line
number. This second check is new. A wrong URL can return an HTML page.
Without the check, that page becomes the key file and locks the machine.

The installer and the runner apply both checks before they touch anything.
Step 10 keeps its current `keys_present` guard. The file it receives
already passed the runner's check.

## Stage 1: install

`install/install.sh` reads `HOMICRON_KEYS_URL`. When the variable is unset
or empty, the script prints usage and exits 2 before it reads the disks.
The usage text names the variable and gives
`https://github.com/<user>.keys` as the example. GitHub serves every public
key on an account at that address, one key per line.

The typed install line becomes:

```
ipadm create-addr -T dhcp <nic>/v4 && echo "nameserver $(dhcpinfo -i <nic> DNSserv)" > /etc/resolv.conf && curl -fsSLo /tmp/i https://homicron.smithjs.org/install && HOMICRON_KEYS_URL=https://github.com/<user>.keys bash /tmp/i <hostname> <disk>...
```

After the site files are fetched and verified, and before `install-helios`
runs, the script fetches the keys URL with `curl -fsSL` into the temporary
directory. A fetch failure exits 1 with the URL in the message. The key
line rule is applied to the fetched file. The file is seeded to
`/a/root/.ssh/authorized_keys` with mode 0600, as today.

The keys URL is not in `SHA256SUMS`. The person typed it, and TLS protects
the fetch. This is the same trust the site address already has.

`/etc/homicron.conf` records `HOSTNAME=<hostname>` and
`KEYS_URL=<url>`. The `BASE_URL` line goes. Nothing reads it. The first-boot
service still sources the file for `HOSTNAME` only.

The site stops serving `keys/`. `pages/build-site.sh` no longer copies the
keys file, and `SHA256SUMS` lists the installer and the three first-boot
files. The `files` array in `install.sh` loses its `keys/authorized_keys`
entry. `keys/authorized_keys` and the `keys/` directory are deleted from
the repository. `test/helpers/fake_site.bash` stops copying keys. The
install tests write their own keys file and serve it through the fake curl
at the fake `HOMICRON_KEYS_URL`.

## Stage 3: apply

### Key source

A new variable, `HOMICRON_KEYS`, names the keys the runner ships. It is
accepted in the hosts file and in the environment under the same syntax
rules as every other variable. It is runner-only: `write_resolved_env`
never writes it to `host.env`, and the steps never see it. `bin/homicron`
keeps a second list, `runner_vars`, for variables of this kind, and
`known_var` accepts a name from either list.

The value is a URL or an absolute path:

- A value that matches `^https?://` is fetched with `curl -fsSL`. A fetch
  failure exits 2 with the URL in the message.
- Any other value is a file path. A path that is not a readable file exits
  2 with the path in the message. The value syntax rule refuses `~`, so
  the doc says to write the path in full.

When `HOMICRON_KEYS` is unset, the runner reads every `~/.ssh/*.pub` file
on the machine that runs `apply`. It appends the files one after another
and makes sure that each one ends with a newline. When that produces no
key line, the runner exits 2 before rsync. The message names the glob and
the variable.

The runner applies the key line rule to the result and writes it to a
temporary file beside the resolved `host.env`. It rsyncs the file to
`/opt/homicron/authorized_keys`, as today. Step 10 does not change. It
still overwrites root's and the user's `authorized_keys` with the shipped
file. The shipped file is the whole list of trusted keys for that machine.

Two workstations that both use the default remove each other's key on
every `apply`. `hosts/README.md` says so. When more than one machine runs
`apply`, point `HOMICRON_KEYS` at one shared URL, the same URL the install
line used.

### User and uid defaults

`HOMICRON_USER` defaults to `id -un` and `HOMICRON_UID` to `id -u` on the
machine that runs `apply`. The two "is required" checks in `load_host` go.
The defaults pass through `valid_value` like every other value, so a login
with a character outside the allowed set exits 2 with the variable name.

`hosts/README.md` states the reason for the uid. Files that move between
the two machines keep their numeric owner. A matching uid keeps that owner
readable on both sides. helios-engvm matches the uid for the same reason.
Both rows become optional in the table.

`hosts/vm.env` keeps only the values that differ from the defaults:

```
HOMICRON_PORT=2222
SWAP_SIZE=4G
DUMP_SIZE=4G
```

### Unreachable message

When ssh or rsync exits 255, the runner's message becomes
`cannot reach <addr>: ssh exited 255 (the box is down, or its host key changed after a reinstall; try ssh root@<addr> by hand)`.
The exit status stays 1.

## The site

### Base URL and repository URL

`pages/build-site.sh` reads two variables. `HOMICRON_BASE_URL` defaults to
`https://homicron.smithjs.org`. `HOMICRON_REPO_URL` defaults to
`https://github.com/jacobthemyth/homicron`. These two lines in
`build-site.sh` and the default line in `install.sh` are the only places
the code names this instance of the project.

When `build-site.sh` copies `install/install.sh` to `install`, it rewrites
the one line that matches `^base_url=\$\{HOMICRON_BASE_URL:-.*\}$` so that
the default inside the braces is `HOMICRON_BASE_URL`. Every other line is
copied as is. The site test that compared the two files byte for byte now
removes that line from both before it compares them. A second test builds
with `HOMICRON_BASE_URL=http://example.test`. It makes sure that the served
`install` contains `:-http://example.test}` and that `install/install.sh`
in the repository is unchanged.

`pages/index.html` holds `{{BASE_URL}}` and `{{REPO_URL}}` where the
address and the repository link appear. `build-site.sh` replaces both. The
site test makes sure that the built page contains no `{{`.

### Custom domain

`pages/CNAME` is deleted and `build-site.sh` stops copying it. A GitHub
Actions workflow deploys this site. For such a site, GitHub reads the
custom domain from the repository settings and ignores a `CNAME` file in
the artifact. The README gives the command that sets the domain:
`gh api -X PUT repos/<owner>/<repo>/pages -f cname=<domain> -F https_enforced=true`.

### Workflow

The `build` and `deploy` jobs in `.github/workflows/pages.yml` merge into
one `deploy` job. It needs `lint`, runs only on a push to `main`, keeps the
`pages` concurrency group, and holds the `pages: write` and
`id-token: write` permissions. Its steps are checkout,
`actions/configure-pages@v5` with id `pages`, the site build with
`HOMICRON_BASE_URL: ${{ steps.pages.outputs.base_url }}` and
`HOMICRON_REPO_URL: ${{ github.server_url }}/${{ github.repository }}` in
its environment, `actions/upload-pages-artifact@v3`, and
`actions/deploy-pages@v4`. A fork enables Pages with the workflow build
type and gets a site at its own `github.io` address with no edit. A custom
domain works the same way.

## Docs

`README.md`:

- The typed install line uses `<nic>` in place of `rge0` and carries
  `HOMICRON_KEYS_URL`. The `[<disk]]` typo becomes `[<disk>]]`.
- Step 5 of "Install a machine" says that root accepts the keys the install
  line named.
- Step 6 says that `apply` ships the public keys of the workstation unless
  the hosts file sets `HOMICRON_KEYS`. It also says that `HOMICRON_USER`
  and `HOMICRON_UID` default to the workstation's login and uid.
- A new section, "Run your own copy", has four steps. Fork the repository.
  Enable Pages with the workflow build type
  (`gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow`).
  If you want a custom domain, set it. Type the install line with your own
  site address and keys URL. The section also says that the published site
  at `homicron.smithjs.org` works for anyone, because the install line
  names the keys.
- The rehearsal section carries `HOMICRON_KEYS_URL` in its typed line and
  says that the VM reaches GitHub through qemu's user-mode network.
- The word laptop goes. The machine that runs `apply` is the workstation.

`hosts/README.md`:

- `HOMICRON_USER` and `HOMICRON_UID` become optional, with their defaults
  and the uid reason.
- A row for `HOMICRON_KEYS`: optional, default "every `~/.ssh/*.pub` on the
  workstation", a URL or an absolute path, runner-only. The paragraph
  below the table explains the overwrite behavior and the shared URL.
- A sentence says that the default address `<name>.local` needs an mDNS
  resolver on the workstation. macOS has one. Many Linux hosts get one
  from avahi or systemd-resolved.
- A sentence says that git ignores `hosts/*.env`, so a hosts file is
  private by default. `vm.env` is the one tracked exception.

`bin/homicron`, `install/install.sh`, and `pages/index.html` lose the word
laptop in their comments and text. The specs and plans under
`docs/superpowers/` keep it as history.

## Tests

`test/install.bats`:

- No `HOMICRON_KEYS_URL`: exit 2, usage names the variable, no
  `install-helios` call, no site fetch.
- Keys URL that the fake curl cannot serve: exit 1, the URL in the output.
- A keys file with an HTML line: exit 1 with the line number.
- The existing no-key, comment-only, `sk-` key, and indented key tests
  move from the site keys file to the fetched keys file.
- Happy path: root's `authorized_keys` equals the fetched file,
  `/etc/homicron.conf` holds `KEYS_URL=` and no `BASE_URL=`.
- `SHA256SUMS` is read with four entries and the `keys/` path is never
  fetched.

`test/homicron.bats`:

- Fix the fixture at line 176 to expect `HOMICRON_USER=vmuser`.
- `HOMICRON_KEYS` as a path: the shipped file equals it.
- `HOMICRON_KEYS` as a URL: the fake curl is called with it and the shipped
  file equals what it served.
- `HOMICRON_KEYS` unset, `HOME` set to a temp dir with two `.pub` files,
  one of them without a trailing newline: the shipped file holds both keys
  on two lines.
- `HOMICRON_KEYS` unset and no `.pub` file: exit 2 before rsync, the
  message names `~/.ssh/*.pub` and `HOMICRON_KEYS`.
- A keys source with an HTML line: exit 2 before rsync.
- `HOMICRON_KEYS` never appears in the shipped `host.env`.
- A hosts file with no `HOMICRON_USER` or `HOMICRON_UID`: the shipped
  `host.env` holds `id -un` and `id -u`.
- Exit 255 output contains `host key`.

`test/site.bats`:

- The layout test drops `CNAME` and `keys/authorized_keys`.
- `SHA256SUMS` has four lines.
- The served `install` equals the source once the `base_url=` line is
  removed from both. The `base_url=` line in the served file holds the
  given `HOMICRON_BASE_URL`.
- The built `index.html` contains the given base URL and repository URL and
  no `{{`.

`test/firstboot.bats` writes `KEYS_URL=` in place of `BASE_URL=` in its
`homicron.conf` fixture.

## Rehearsal

On the Arch host, with `test/serve.sh 8000` in one terminal and
`test/qemu.sh install` in another:

1. At the installer prompt, run the typed line from the README with
   `vioif0`, `HOMICRON_BASE_URL=http://10.0.2.2:8000`, and
   `HOMICRON_KEYS_URL=https://github.com/<user>.keys`. Make sure that the
   output says `fetching keys from` and that `install-helios` runs.
2. Run the line once more with `HOMICRON_KEYS_URL` unset. Make sure that
   it exits 2 with usage and does not touch the disk.
3. Reboot into the installed disk with `test/qemu.sh boot` and make sure
   that `ssh -p 2222 root@<arch-host> cat /etc/homicron.conf` shows
   `KEYS_URL=`.
4. From the workstation, with no `hosts/vm.env` values for user or uid,
   run `HOMICRON_ADDR=<arch-host> bin/homicron apply vm`. Make sure that
   the user it creates is the workstation login with the workstation uid,
   and that `bin/homicron ssh vm` logs in.
5. Run `apply` a second time and make sure that every step reports its
   check passing.
