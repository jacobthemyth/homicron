# Can voxel sleds run on bare metal so that they run VMs?

Date: 2026-11-02. Sources read: voxel `a6ad27b`, falcon `6bfdb16` (voxel pins
`6b1494b`), softnpu `a6a8785`, omicron `50db5ad`. Clones are in the session
scratchpad, not in this repository.

## Answer

Yes, the architecture is possible. Omicron supports it today without voxel.
The omicron guide `docs/how-to-run.adoc` lists two development modes. The
second mode is "one or more real Sled Agents (on separate physical machines)
using SoftNPU-based Boundary Services. You can provision real VMs this way."
It also says that this mode runs on "ordinary server PCs".

The guide documents only the single-machine case. It says that sled-to-sled
networking through SoftNPU works "just like Tofino" but is "beyond the scope
of this doc". The multi-machine case is therefore supported in the code and
undocumented in practice.

voxel itself cannot become multi-host with small changes. Its sleds, routers,
and switch fabric are falcon objects, and falcon builds everything on one
host. The parts of voxel that carry over are the configuration generators.

## How the pieces work

falcon starts each node as a propolis VM on the local host. A link between two
nodes is a pair of simnet devices, which are illumos virtual Ethernet links
joined back to back. Each simnet end gets a VNIC that the VM uses. Nothing in
falcon spans two hosts. The one exception is `ext_link`, which puts a VM NIC
on a VNIC over a host data link such as `igb1`.

SoftNPU is a software model of the Tofino switch chip in an Oxide Sidecar
switch. It runs a P4 program, `sidecar-lite`, and moves packets between ports.
Two implementations exist.

1. A propolis device. The switch lives inside a scrimlet VM, and each port is
   a host link. voxel uses this one. The sled-agent configuration is
   `deployment = { kind = "virtual", ... }`.
2. A standalone program in a zone, built by `npuzone`. Each port is any
   illumos data link that the zone opens with DLPI. Omicron's
   `cargo xtask virtual-hardware create` uses this one. The sled-agent configuration
   is a `custom` deployment with the `soft_npu_zone` switch.

A scrimlet is a sled that manages a switch. Its switch zone runs dendrite,
which programs SoftNPU, and Maghemite, which routes the underlay. The underlay
is the internal IPv6 network between sleds. It needs jumbo frames.

The second implementation is the key. Its ports are ordinary data links, so a
port can be a VNIC over a physical NIC, or a VLAN link. That lets a switch
port reach a sled on another machine through a cable or a VLAN on an Ethernet
switch.

## Target architecture

Every sled is a physical Helios machine that runs sled-agent in its global
zone. Instances run as propolis zones on those machines, so bhyve does not
nest.

One machine (two for a two-switch rack) is a scrimlet. It runs a standalone
SoftNPU zone. Each rear port of that zone is a VLAN VNIC over one physical
NIC. Each VLAN is a point-to-point segment to one other sled. The scrimlet's
own sled-agent reaches its own SoftNPU through a simnet pair, as in the
single-machine guide. One front port is the uplink to the home network.

Each other sled lists its link to each switch in sled-agent `data_links`. A
managed Ethernet switch with VLANs and 9000-byte MTU carries the segments.
If the scrimlet has a NIC port per sled, direct cables also work.

The FRR routers stay optional. Static routing on the uplink is enough for a
home lab. The routers can stay falcon VMs on any host, because they are Linux
guests with no nesting.

## Work required

| Area | Work | Size |
|---|---|---|
| Hardware | At least 3 machines for VM disks: Crucible puts the 3 copies of each disk on 3 different sleds in `multi-sled` mode. Each machine needs 2 NIC ports or VLAN support, and the switch needs jumbo frames. | purchase |
| Host install | homicron already installs Helios. Add the OPTE `xde` driver package, the vmm reservoir, and file-backed vdevs on each machine. | small |
| Omicron packages | Build the omicron packages once with the `non-gimlet` target and install them on each host with `omicron-package install`. voxel bakes them into a VM image instead, so this path is new. | medium |
| Scrimlet | Create the SoftNPU zone with one `--ports` pair per sled, initialize it with `scadm` for the uplink, and set `switch_zone_maghemite_links` to the `tfportrear*` links. | medium |
| Sled configuration | Generate a sled-agent `config.toml` per machine: `custom` deployment, `data_links`, vdevs. `voxel-config/src/sled.rs` already does this for VMs. | small |
| Rack setup | Generate `config-rss.toml` and start rack setup with it. `voxel-config` already renders it with omicron's own types. | small |
| Identity | A PC reports its hostname as the serial number. voxel sets SMBIOS to `a4x2` so that trust quorum certificates match. The certificate staging must use hostnames instead. | medium, risk |
| Lifecycle | Uninstall, reinstall, and reboot runbooks per machine. A machine reboot is a real sled reboot, which voxel cannot test today. | medium |

The total is a new tool, or a second voxel backend, of several weeks for one
person. Most of the time goes to the risks below, not to code.

## Risks and unknowns

1. No public example of multi-machine SoftNPU-zone omicron was found.
   sled-agent still points dendrite at
   `softnpu_single_sled_config.toml`, even for voxel's multi-sled propolis
   switches. voxel proves that this file works for many sleds, but only for
   the propolis device.
2. PCs have no service processor. Nexus finds sleds to add from the
   service processors in inventory (`nexus/src/app/rack.rs`,
   `sled_list_uninitialized`). A PC sled can therefore only join at rack setup,
   unless sp-sim pretends to be its service processor. A `soft_npu_zone`
   scrimlet starts sp-sim in its switch zone by itself
   (`sled-agent/src/services.rs`). This path is known but untested on real
   hardware.
3. Trust quorum depends on attestation certificates that match each sled's
   baseboard. voxel generates mock certificates for SMBIOS serials. The PC path
   uses hostnames, and `sled-hardware` notes that this exists for an older
   lab called the "Canada region".
4. SoftNPU forwards every packet in software. Expect throughput far below the
   NIC speed for instance traffic between sleds and for external traffic.
5. Omicron moves fast. voxel pins omicron and keeps up with schema drift. A
   bare-metal tool needs the same discipline.

## A smaller step: one physical compute sled in a voxel rack

falcon can grow a SoftNPU port backed by a physical link. Today `ext_link`
makes only a viona endpoint. An `ext_link` variant with a SoftNPU endpoint is
a change of tens of lines in `lib/src/lib.rs`. With it, a scrimlet VM's switch
port reaches a physical PC through a cable or VLAN.

That PC runs sled-agent as a compute sled. The VM sleds keep the control plane
and can hold Crucible copies, because Crucible runs in zones, not VMs. Set the
VM sleds to non-provisionable so that Nexus places instances only on the PC.
This needs two machines in total: homicron00 and one compute PC. Risk 2
applies, so the PC must be in the first rack setup, with an sp-sim entry.

## The cheapest path to VMs on this hardware

Omicron's single-machine mode runs real VMs on homicron00 today, with no
voxel. Follow `docs/how-to-run.adoc` with the `dev` preset and the
`single-sled` Nexus policy. This gives the Oxide API, the console, and real
instances on one machine, without the multi-sled control plane that voxel
models. It is a reinstall of the rack layer, not of Helios.

## Rack setup, the physical switch, and service processors

Added 2026-11-02 after a follow-up question. Sources: omicron `50db5ad`,
maghemite at its `main` of the same day.

### Rack setup without service processors

RSS (the rack setup service) has two entry points. The wicket path asks MGS
(the management gateway service) for the sleds, and MGS learns them from
service processors. The file path reads `config-rss.toml` on one sled and
needs no service processor. Omicron's own PC guide uses the file path.

The file chooses how RSS finds the other sleds with
`bootstrap_discovery.type`. The values are `only_ours`, `only_these` with a
list of bootstrap addresses, and `everyone`. A bootstrap address comes from
the MAC address of the sled's data link. RSS reaches the other sleds over the
bootstrap network, which runs on the same links as the underlay.

Each sled needs its own trust quorum identity. sled-agent reads test
certificates from the `[sprockets]` table in its `config.toml`. voxel
generates one numbered set per sled and gives each VM a matching SMBIOS
serial (`2FAKE00<n>`). A PC uses its hostname as the serial. The likely
approach is to name each host after the serial in its certificate. This is
unverified.

### Why the physical switch cannot be a plain switch

ddm, the underlay routing daemon, keeps one neighbor per interface
(`maghemite/ddm/src/sm/state.rs`). Sleds run ddm as servers, and only a
transit router passes routes on. The transit router is the ddm in the switch
zone of a scrimlet. The packets themselves move through the switch chip,
which SoftNPU models. Geneve tunnels, NAT, and external addresses for
instances also live in the switch chip program.

The result is that a programmable switch must exist, and SoftNPU on a PC is
that switch. The physical Ethernet switch only replaces cables. It must give
each sled a private point-to-point segment to the scrimlet. An unmanaged
switch puts every sled on one segment, so ddm sees many neighbors on one
link.

### Wiring with one managed switch

1. Configure one VLAN per sled on the managed switch, with 9000-byte frames.
2. Make each sled's switch port an untagged member of that sled's VLAN.
3. Make the scrimlet's switch port a tagged member of every sled VLAN.
4. On the scrimlet, create one VLAN VNIC per sled over that NIC.
5. Give each VLAN VNIC to the SoftNPU zone as one rear port.
6. Give a second NIC on the home LAN to the SoftNPU zone as the front port.

If the scrimlet has one NIC port per sled, direct cables replace steps 1 to 4.
All traffic between sleds passes through the scrimlet's one trunk port and
through software. A second switch for redundancy doubles the VLANs and needs
a second scrimlet and a second NIC on each sled.

### Service processors

No physical service processor is needed for rack setup, for instances, or for
routine operation. sp-sim in the scrimlet's switch zone gives MGS simulated
service processors. Physical ones give power control, host flash updates,
and firmware updates. A development board running Hubris cannot control a
PC's power or read its host flash, so it adds nothing for that PC.

One real board is useful as a firmware test target beside sp-sim. voxel
already mixes real-firmware and simulated service processors per slot
(`[sp] emu`), but it emulates the real ones with sp-emu. Mixing a physical
board into a PC rack is untested.

## Scope of a bare-metal rack without a Sidecar

Added 2026-11-02. This replaces the "Target architecture" section for a
design with a layer-2 underlay switch and a separate edge box. Sources:
omicron `50db5ad`, maghemite and opte at their `main` of the same day.

### Physical layout

- Sleds: Helios PCs with Chelsio T520-CR cards. Under Helios, `cxgbe` offers
  Geneve checksum and segmentation offload from T5 onward. Upstream illumos
  does not.
- Underlay: one VLAN with jumbo frames on a MikroTik CRS309, switched in
  hardware at layer 2. The CRS309 routes IPv6 in its CPU, so it does no
  routing.
- Edge box: the machine that does the switch's work for traffic in and out of
  the rack.

### Work items

1. Underlay routing. ddm runs in the global zone of each sled today, and it
   keeps one peer per link. The replacement also runs on each sled. It
   learns the other sleds directly on the shared VLAN and installs routes
   with each sled as the next hop. It must serve ddm's admin API, because
   sled-agent uses it for bootstrap discovery and for prefix advertisement
   (`sled-agent/src/ddm_reconciler.rs`, `bootstrap/server.rs`). The smallest
   version is a patch to ddm that accepts many peers on one link. It must
   also carry a route to the edge box. OPTE sends traffic for the outside
   world to boundary services on VNI 99 (`opte/lib/oxide-vpc/src/api.rs`).
2. dendrite backend. dendrite (`dpd`) does not run on every sled. It runs in
   the switch zone of each scrimlet, one per switch, and its backends are
   code inside `dpd`. Nexus calls its API for NAT entries, switch ports,
   instance networking, probes, LLDP, and multicast. The new backend drives
   the edge box over the network.
3. Switch-zone helpers. `tfportd` reads the control packets that the switch
   sends to its CPU, such as NDP, ARP, LLDP, and BGP. In voxel it already
   reads them from an ordinary NIC, `vioif0`
   (`sled-agent/src/services.rs`). A dedicated port or VLAN from the edge box
   to the scrimlet can play the same role. `uplinkd` and `mgd` need review for
   the same assumption. This item is smaller than items 1 and 2.
4. Edge box. It must implement what dendrite programs: NAT entries that wrap
   packets in Geneve, routes, neighbor tables, and uplink addresses. The P4
   program `sidecar-lite.p4` is the specification, but the edge box does not
   need to run P4. A ConnectX-6 under Linux with DPDK `rte_flow` is one
   option.

For a first version, SoftNPU can be the edge box. SoftNPU needs illumos
(DLPI and zones), so that box runs Helios, not Linux. dendrite talks to
SoftNPU through a Unix socket or a serial line today, so a network transport
is new work.

### What runs unmodified

Helios, propolis, Crucible, Nexus, OPTE, and MGS with sp-sim run unmodified.
sled-agent runs with configuration only:

- A `custom` deployment.
- Trust quorum with software test keys. The `non-gimlet` configuration ships
  them under `[sprockets]`, so trust quorum is not stubbed. It runs without
  hardware protection.
- Real NVMe drives through
  `external_disks = { kind = "hardcoded", disks = [...] }`. voxel already
  feeds its NVMe disks to sled-agent this way. This corrects the
  "file-backed fake disks" statement earlier in this document.

### What the design loses

- The hardware root of trust and attestation.
- SP functions: power control, firmware updates, and host OS updates through
  Oxide's update system. Plan to update the operating system by hand.
- Sleds after rack setup. A PC can join later only with an sp-sim entry that
  stands in for its SP.
- Switch redundancy. One edge box is a single point of failure for traffic in
  and out of the rack. Traffic between sleds does not depend on it.

## Updates, adding sleds, and rack setup with sp-sim

Added 2026-11-02. Sources: omicron `50db5ad`, voxel `a6ad27b`.

### Operating system updates

A Nexus-driven update writes host phase 1 through the SP into the host flash.
sled-agent writes host phase 2 to a boot slot on an M.2 disk
(`sled-agent/config-reconciler/src/host_phase_2.rs`). The SP then resets the
host, which boots the new image. sp-sim stores phase 1 in memory, and it
cannot reset a PC. A PC boots Helios from its own loader, not from the M.2
slots, so it never runs the new host image.

The planner holds every control plane zone update until the SP, root of
trust, and host OS updates finish. See `PendingMgsUpdates` and
`BlockedMgsUpdates` in `nexus/reconfigurator/planning/src/planner.rs`. A host OS update that never finishes therefore also
blocks zone updates. I did not trace the timeout path.

voxel avoids this at launch. It seeds sp-sim with the release's host phase 1
and writes the release's phase 2 to each M.2 disk. The reported images then
match the release. A PC rack can use the same method for its first release.
An upgrade to a later release will stop at the host OS step. Plan to upgrade
by reinstalling, or by a MUPdate-style manual procedure.

### Adding a sled after rack setup

Nexus lists sleds to add from the SPs in inventory, so the new PC needs an
sp-sim entry. Nexus then asks a running sled-agent to find the new sled.
That sled-agent connects to every bootstrap address that ddm knows and reads
the platform ID in each peer's sprockets certificate
(`find_sprockets_stream` in `sled-agent/src/sled_agent.rs`). The platform ID
holds a part number and a serial number. The sp-sim entry must carry the same
two values as the new sled's certificate.

The sled's own identity must also match its certificate. If the SMBIOS manufacturer is `a4x2`,
`sled-hardware` reads the identity from SMBIOS. Otherwise it uses the
hostname as the serial number and the platform name as the part number.
voxel sets SMBIOS on its VMs for this reason. On a PC, either rewrite the
SMBIOS type 1 strings with the board vendor's DMI tool, or patch
`sled-hardware`.

### Rack setup

RSS starts from `config-rss.toml` on the scrimlet, or from wicketd. wicketd
works because MGS sees sp-sim, and voxel uses this path on every launch.

1. Every host boots, and its bootstrap agent advertises a bootstrap prefix
   through the ddm replacement. The scrimlet starts its switch zone.
2. RSS finds the other sleds and starts trust quorum over sprockets.
3. RSS writes the early network configuration, with uplink addresses and
   routes, to the bootstore. The scrimlet applies it through dendrite and
   mgd, so the edge box gets its uplink before any service needs it.
4. RSS gives each sled its underlay subnet and starts internal DNS and NTP.
   Boundary NTP reaches the internet through the edge box, and RSS waits for
   time sync.
5. RSS starts CockroachDB and Nexus, then hands the rack to Nexus. Nexus
   programs the NAT entries for its own external addresses and for external
   DNS.

Steps 3 to 5 use the dendrite backend and the edge box. Both must work before
the first rack setup can finish. `skip_timesync` in the sled-agent
configuration removes the wait in step 4 for development.
