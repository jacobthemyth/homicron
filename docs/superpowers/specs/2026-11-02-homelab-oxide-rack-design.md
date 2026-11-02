# Homelab Oxide rack: a specification of specifications

Date: 2026-11-02. Status: draft for review.

This document specifies a "homelab Oxide rack": the Oxide software stack on
commodity x86 machines, with real virtual machines, and without an Oxide
Sidecar switch. It is a specification of specifications. Each component
section states the requirements that are known today and names the
subcomponents that need their own design before any work can start. It is
not a plan, and nothing in it can be built directly.

The evidence for each claim is in
`2026-11-02-voxel-multi-host-investigation.md` in this directory and in the
source references in Appendix B.

## 1. Purpose, scope, and non-goals

### Purpose

The rack runs small-business or homelab workloads as Oxide instances. It
uses the Oxide API, console, VPC networking, and Crucible disks. Each sled is
a physical machine, so instances run in bhyve without nested virtualization.

### Scope

- Three or more x86 machines that run Helios and sled-agent.
- One layer-2 Ethernet switch for the rack-internal network.
- One edge box that does the Sidecar's work for traffic in and out of the
  rack.
- New and changed software where the Oxide stack assumes Oxide hardware.

### Non-goals

- Production durability or support. Upstream Oxide does not support this
  configuration.
- A hardware root of trust or measured boot.
- Switch redundancy. The design has one edge box and one underlay switch.
- Firmware updates. The machines have no Oxide service processors.
- Multi-rack configurations.

### Design principle

Use Oxide software unmodified wherever configuration is enough. Where a
change is necessary, make it at an existing boundary. Examples are a dendrite
backend, a sled-agent switch kind, and a protocol that already has an API.

## 2. Terms

| Term | Meaning in this document |
|---|---|
| sled | A machine that runs sled-agent. Here, a Helios PC. |
| scrimlet | A sled that manages a switch. It runs the switch zone. |
| switch zone | The `oxz_switch` zone. It runs dendrite, mgd, MGS, wicketd, tfportd, uplinkd, and lldpd. |
| underlay | The rack-internal IPv6 network between sleds. It uses jumbo frames. |
| bootstrap network | IPv6 addresses derived from each sled's MAC address. Sleds use them before rack setup. |
| boundary services | The switch function that joins VPC traffic to outside networks. |
| edge box | The machine that runs the boundary services dataplane in this design. |
| dataplane | The code or hardware that forwards each packet. |
| punt path | The path that carries switch control packets between switch ports and the switch zone. |
| SP | Service processor: the management controller on an Oxide sled. sp-sim simulates one. |
| RSS | Rack setup service. It turns a set of sleds into a rack. |
| Geneve | The tunnel format that carries VPC traffic on the underlay. VNI is its network identifier. |
| OPTE | The Rust kernel module on each sled that implements VPC networking for instances. |
| ddm | Maghemite's underlay routing protocol and daemon. |

## 3. System overview

```
                      home network / internet
                                |
                         uplink | (standard MTU)
                       +--------+--------+
                       |    edge box     |---- punt link (VLAN) ----+
                       | boundary svcs   |                          |
                       +--------+--------+                          |
                                | underlay port (jumbo)             |
  +-----------------------------+---- layer-2 switch, underlay VLAN-+------+
  |                    |                     |                           |
+-+--------------+  +--+-------------+   +---+------------+         +----+---+
| sled 0         |  | sled 1         |   | sled 2         |   ...   | sled N |
| scrimlet:      |  | sled-agent     |   | sled-agent     |         |        |
|  switch zone   |  | OPTE, propolis |   | OPTE, propolis |         |        |
| sled-agent     |  | Crucible       |   | Crucible       |         |        |
| OPTE, propolis |  | routing daemon |   | routing daemon |         |        |
| routing daemon |  +----------------+   +----------------+         +--------+
+----------------+
```

The diagram shows version 1, with a separate edge box. Every sled has one
underlay link to the layer-2 switch. All sleds and the
edge box share one underlay VLAN. Each sled installs a route to every other
sled with that sled as the next hop. Traffic between sleds therefore never
passes through the edge box. The switch forwards Ethernet frames in hardware and
does no IP routing.

One sled is the scrimlet. Its switch zone runs the control plane for the
edge box. dendrite programs the edge box's tables, and mgd runs BGP or static
routes for the uplink. Control packets from the uplink, such as ARP, NDP,
LLDP, and BGP, reach the switch zone over the punt link.

In version 0, the edge box is a SoftNPU zone on the scrimlet itself, which
is a configuration that omicron already supports for one machine. In version
1, the edge box is a separate machine with NIC hardware offload.

### Software that runs unmodified

Helios, propolis, Crucible, Nexus, CockroachDB, ClickHouse, internal and
external DNS, Oximeter, OPTE, MGS, sp-sim, wicketd, and the web console run
unmodified. sled-agent runs with configuration only in version 0. Section 6
lists that configuration.

### Software that changes

| Software | Change | Component |
|---|---|---|
| ddm (maghemite) | Many peers on one link, or a replacement daemon with the same API | C3 |
| dendrite | A backend for a remote edge box (version 1 only) | C4, C5 |
| sled-agent | A switch kind for a remote edge box (version 1 only) | C4 |
| sled-hardware | Optional: a sled identity source other than SMBIOS | C6 |
| sp-sim configuration | One entry per sled, with identities that match the certificates | C4, C6 |

## 4. Packet paths

### P1. Instance to instance on different sleds

1. The guest sends a frame to its virtual NIC.
2. OPTE on the source sled applies VPC rules and wraps the frame in Geneve.
   The outer IPv6 destination is the destination sled's underlay address.
3. If the NIC offers Geneve offloads under Helios, it computes checksums
   and splits large TCP sends.
4. The source sled's route for the destination sled's /64 names the
   destination sled's link-local address as the next hop.
5. The layer-2 switch forwards the frame to the destination sled.
6. OPTE on the destination sled unwraps the frame and delivers it.

The edge box and the scrimlet do not take part.

### P2. Crucible replication

An instance's disk is a Crucible volume with three copies on three sleds.
The Crucible client runs inside propolis. It sends plain IPv6 TCP to three
Crucible storage zones on the underlay, over the same path as P1 without
Geneve. Storage traffic is the largest flow in the rack, and it never
touches the edge box.

### P3. Outside world to instance

1. A packet for an external IP address arrives on the edge box's uplink.
2. The edge box looks up the external address and port in its NAT table.
   An entry names a sled's underlay address, an inner MAC address, and a
   VNI.
3. The edge box wraps the packet in Geneve with that VNI and with one
   4-byte Oxide option, class `0x0129`, "VPC-external packet".
4. The layer-2 switch delivers it to the sled.
5. OPTE unwraps the packet and translates the external address to the
   instance's private address.

The edge box does not translate addresses. OPTE on the sled does.

### P4. Instance to outside world

1. OPTE translates the source address and wraps the packet in Geneve on
   VNI 99, the boundary services VNI.
2. The outer destination is the boundary services address. ddm told OPTE
   which boundary address serves which outside prefix.
3. The sled's route for the boundary address leads to the edge box.
4. The edge box unwraps the packet, looks up a route, resolves the next hop,
   and sends it out the uplink.

### P5. Switch control packets

1. ARP, NDP, LLDP, and BGP packets arrive on an edge box port.
2. The edge box sends them to its CPU port with a sidecar header. The header
   carries a code and the ingress port number.
3. tfportd in the switch zone reads them from its packet source and delivers
   each one to the `tfport` link for that port.
4. mgd, lldpd, and the kernel answer on the `tfport` link. tfportd sends the
   replies back with a sidecar header that names the egress port.

### P6. Bootstrap and rack setup

Before rack setup, sleds have only bootstrap addresses. The routing daemon
advertises them on the underlay VLAN. RSS and the sled agents use them for
discovery, for trust quorum over sprockets, and to hand out underlay
subnets.

## 5. Components

Each component section has the same parts: role, requirements, interfaces,
known facts, open questions, and subcomponents. Requirement identifiers have
the form `C<n>-R<m>`. Subcomponent identifiers have the form `SC<n>.<m>`.

### C1. Sled host

Role: a physical machine that runs Helios, sled-agent in the global zone,
control plane zones, propolis instances, and OPTE.

Requirements:

- C1-R1: The host runs Helios built from Oxide's `stlouis` branch of
  illumos-gate. Upstream illumos lacks the Geneve offloads in `cxgbe`.
- C1-R2: The CPU supports hardware virtualization for bhyve.
- C1-R3: The host has enough memory for the control plane zones and a vmm
  reservoir for instances. The reservoir is set with
  `vmm_reservoir_percentage` or `vmm_reservoir_size_mb`.
- C1-R4: The host has one underlay NIC port of 10 Gb or more that accepts
  9000-byte frames.
- C1-R5: The underlay NIC offers Geneve checksum offload and Geneve TCP
  segmentation offload under Helios. Without them, OPTE still works, and the
  illumos MAC layer does the work in software.
- C1-R6: The host has a management path for SSH outside the rack. It is a
  second NIC port or a tagged VLAN on the underlay port.
- C1-R7: The host has NVMe drives for two sled-agent disk roles. "M.2"
  internal disks hold boot slots and configuration. "U.2" disks hold
  Crucible data and zones. In the simplest design, the Helios root pool is
  on another drive.
- C1-R8: The host has the OPTE `xde` driver installed.
- C1-R9: The host reports an identity that matches its trust certificate
  (see C6).

Interfaces:

- sled-agent `config.toml` (section 6).
- OPTE uses the underlay link that sled-agent names in `data_links`.
- Crucible and zones use the disks that sled-agent receives through
  `external_disks`.

Known facts:

- The `cxgbe` driver in `stlouis` offers Geneve checksum and segmentation
  offload on Chelsio T5 and T6 (`t4_mac.c`). It has no T7 support.
- OPTE asks the underlay NIC for these offloads and falls back to software
  emulation in MAC. It also raises the TCP segment size to fit 9000-byte
  frames inside the rack (`opte/xde/src/xde.rs`).
- sled-agent accepts real drives through
  `external_disks = { kind = "hardcoded", disks = [...] }`. voxel feeds its
  NVMe drives to sled-agent this way (`voxel-init/src/gimlet.rs`).
- voxel creates the M.2 partition layout and seeds the host phase 2 image on
  its M.2 drives (`ensure_m2_layout`, `seed_boot_image`).

Open questions:

- Can one physical NVMe drive hold both the Helios root pool and an M.2
  role, with partitions? The simplest design uses separate drives.
- How many sleds does the rack need for Nexus to place three Crucible copies
  and its own redundant services? The floor is three. The default voxel
  topology uses four.

Subcomponents:

- SC1.1 Host profile: the homicron steps for a sled (packages, `xde`, vmm
  reservoir, NIC MTU).
- SC1.2 Disk role mapping: choose drives for the M.2 and U.2 roles, create
  the M.2 layout, and render the `hardcoded` disk list.
- SC1.3 Omicron install on bare metal: install, start, stop, and remove
  sled-agent and its packages on a PC.

### C2. Underlay fabric

Role: a layer-2 Ethernet switch that joins every sled and the edge box.

Requirements:

- C2-R1: The switch forwards frames in hardware at full speed on every port
  in use.
- C2-R2: The switch carries 802.1Q VLANs in hardware.
- C2-R3: The underlay VLAN carries frames of 9000 bytes plus headers.
- C2-R4: The underlay VLAN floods IPv6 link-local multicast to every port in
  the VLAN. NDP and routing daemon discovery depend on it. If the switch does
  MLD snooping, the snooping must not drop these groups.
- C2-R5: The switch does not route the underlay. Routing happens on the
  sleds.
- C2-R6: The design uses separate VLANs for the underlay, the management
  network, and the version 1 punt link. The uplink can also use a VLAN on the same
  switch.

Interfaces:

- Ethernet only. No Oxide software talks to the switch.

Known facts:

- ddm needs a private segment per peer today, so a shared VLAN depends on
  C3.
- A switch that routes IPv6 in its CPU cannot act as the underlay router.
  The reference switch is one of these (Appendix A).

Open questions:

- Does the bootstrap network need anything beyond the underlay VLAN? Today
  both run on the same links.

Subcomponents:

- SC2.1 VLAN, MTU, and port plan.
- SC2.2 Switch configuration as code, applied by C8.

### C3. Underlay routing daemon

Role: replace ddm's behavior on a shared layer-2 segment. Each sled learns
the other sleds and the edge box directly, without a transit router.

Requirements:

- C3-R1: The daemon serves ddm's admin API on each sled. It supports what
  sled-agent uses: advertising and withdrawing prefixes, listing learned
  prefixes, and listing peers' bootstrap addresses. sled-agent calls it in
  `ddm_reconciler.rs`, `bootstrap/server.rs`, `bootstore_setup.rs`, and
  `find_sprockets_stream` in `sled_agent.rs`.
- C3-R2: The daemon discovers many peers on one link.
- C3-R3: The daemon installs a route for each learned prefix with the
  advertising peer's link-local address as the next hop. When the peer
  expires, the daemon removes the route.
- C3-R4: The daemon carries tunnel origins. A tunnel origin maps an outside
  prefix to a boundary services address and VNI. On each sled, the daemon
  programs OPTE with them through `set_v2b` and `clear_v2b`, as ddm does in
  `ddm/src/sys.rs`.
- C3-R5: The daemon makes the boundary services address reachable at the
  edge box. Either the edge box runs the daemon, or the scrimlet advertises
  the address with the edge box as the next hop.
- C3-R6: The daemon works before rack setup, for bootstrap prefixes, and
  after it, for underlay prefixes.
- C3-R7: The daemon reacts to a sled loss within seconds, so that Crucible
  and Nexus see the failure through normal timeouts.

Interfaces:

- ddm admin API (HTTP on localhost).
- The illumos routing table in the global zone.
- OPTE's virtual-to-boundary table.
- mgd in the switch zone, which originates tunnel origins for the uplink's
  outside prefixes.

Known facts:

- ddm discovery solicits on `ff02::dd` and already receives every peer on a
  shared link. Its state machine keeps one peer per interface
  (`ddm/src/sm/state.rs`).
- Only a transit router passes routes on. Sleds run as servers.
- ddm installs learned routes with the peer address as the next hop
  (`ddm/src/exchange/runtime.rs`).
- The ddm runtime is illumos-only. An edge box on Linux cannot run it today.

Approach:

- Preferred: patch ddm so that a server accepts many peers on one interface
  and installs routes from each. This keeps the API, the protocol, and the
  OPTE programming.
- Alternative: a new daemon that serves the same admin API.

Open questions:

- Does mgd originate tunnel origins through the local ddm admin API? Does
  that path still work with the switch zone's ddm as a server on a shared
  link?
- Does a full mesh of peers on one VLAN scale to the sled counts in scope?
  At eight sleds this is small.

Subcomponents:

- SC3.1 Multi-access discovery and peer state.
- SC3.2 Route exchange between servers without a transit router.
- SC3.3 Route installation and expiry.
- SC3.4 Tunnel origins and OPTE virtual-to-boundary programming.
- SC3.5 Edge box participation: the daemon on the edge box, or a proxy
  advertisement from the scrimlet.

### C4. Scrimlet and switch zone

Role: one sled runs the switch zone, which controls the edge box and holds
the rack's switch-side services.

Requirements:

- C4-R1: One sled runs as a scrimlet through a `custom` deployment with
  `sled_mode = "scrimlet"`.
- C4-R2: dendrite programs the edge box. In version 0 it uses the existing
  `soft_npu_zone` backend over its Unix socket. In version 1 it uses a new
  backend that reaches a remote edge box over the network.
- C4-R3: In version 0, tfportd reads punted packets from the SoftNPU zone
  as it does today. In version 1, it reads them from the punt link, in the
  same way that it reads them from `vioif0` in voxel.
- C4-R4: MGS runs with sp-sim. sp-sim has one gimlet entry per sled and one
  sidecar entry. Each sled entry carries that sled's serial and part numbers
  from its certificate.
- C4-R5: mgd runs BGP or static routes for the uplink and originates tunnel
  origins for outside prefixes (C3-R4).
- C4-R6: uplinkd and lldpd work on the `tfport` links that tfportd creates.

Interfaces:

- dendrite's API (`dpd`), which Nexus calls for NAT entries, switch ports,
  instance networking, probes, LLDP, and multicast
  (`nexus/src/app/*.rs`).
- dendrite's backend boundary. Today's backends are `tofino_asic`,
  `tofino_stub`, `soft_npu_propolis_device`, and `soft_npu_zone`.
- sled-agent's switch zone setup in `sled-agent/src/services.rs`. It starts
  sp-sim on its own for the `soft_npu_zone` backend.

Known facts:

- sled-agent points dendrite at `softnpu_single_sled_config.toml` for both
  SoftNPU backends. voxel runs many sleds with it on the propolis device.
- dendrite reaches a SoftNPU zone through a Unix socket and a SoftNPU
  propolis device through a serial line.
- dendrite's source is public.

Open questions:

- Does RSS accept a multi-sled rack with one switch? Racks and voxel
  normally have two scrimlets.
- Which uplinkd, mgd, and lldpd behaviors assume a local Tofino?
- Does a version 1 backend need a new sled-agent switch kind, or only new
  service properties for dendrite?

Subcomponents:

- SC4.1 dendrite remote backend (version 1).
- SC4.2 Edge control protocol, shared with SC5.5.
- SC4.3 Punt link and tfportd packet source.
- SC4.4 sled-agent switch kind for a remote edge box (version 1).
- SC4.5 sp-sim fleet configuration.
- SC4.6 Review of uplinkd, mgd, and lldpd assumptions.

### C5. Edge box

Role: the boundary services dataplane, with uplink ports to the outside
world and one port on the underlay VLAN.

Requirements:

- C5-R1: The edge box implements the parts of `sidecar-lite.p4` that a
  single-switch homelab rack uses:
  - NAT entries that wrap inbound packets in Geneve with a VNI, an inner
    MAC, and the Oxide option `0x0129` (P3).
  - Unwrapping of VNI 99 packets toward the uplink (P4).
  - IPv4 and IPv6 routes toward the uplink, with next hop resolution.
  - ARP and NDP tables.
  - Uplink addresses.
  - Punt and inject with the sidecar header (P5).
- C5-R2: dendrite programs every table in C5-R1, through SoftNPU's
  management channel in version 0 and through SC5.5 in version 1.
- C5-R3: The underlay port carries 9000-byte frames. The uplink uses the
  outside network's MTU.
- C5-R4: The boundary services address reaches the edge box (C3-R5).
- C5-R5: Version 0 is functional at any speed. Version 1 forwards traffic
  in and out of the rack at the uplink's line rate for large packets.

Interfaces:

- Ethernet to the underlay VLAN, the uplink, and the punt link.
- The edge control protocol (SC5.5) or SoftNPU's management channel.

Known facts:

- SoftNPU standalone runs the compiled P4 program on the CPU behind one
  lock (`softnpu/client/src/bin/softnpu.rs`). It makes one system call per
  packet received and one per packet sent. It needs illumos.
- In omicron's single-machine guide, the SoftNPU zone has one rear port and
  one front port, both ordinary illumos links.
- DPDK's mlx5 driver on ConnectX-6 Dx and later supports raw Geneve encap
  and decap rules, Geneve option matching, and header rewrites. Option
  matching needs a firmware parser setting.
- Intel E810 offloads Geneve rules through `tc flower` on Linux. Its guide
  does not cover Geneve options.
- illumos `mlxcx` exposes only MAC and VLAN steering, so a version 1 edge box
  runs Linux.

Versions:

- Version 0: a SoftNPU zone on the scrimlet. Its rear port is a VNIC on the
  underlay VLAN and its front port is the uplink NIC. This is the existing
  `soft_npu_zone` path with different port wiring.
- Version 1: a Linux machine with a ConnectX-6 Dx or later. Each NAT entry
  becomes one NIC rule with a prebuilt outer header. Packets that miss every
  rule go to a software slow path.

Open questions:

- In this design every sled sits behind one rear port, with different next
  hops. Does `sidecar-lite` route correctly in that case? Today each sled has
  its own rear port.
- How does a version 1 edge box match NAT port ranges? NIC rules match exact
  values or masks, so a range splits into several rules.
- Does the NIC compute the outer UDP checksum after encap? IPv6 requires it
  unless both ends accept zero checksums for tunnels.

Subcomponents:

- SC5.1 Dataplane feature set: the exact subset of `sidecar-lite.p4` that
  the rack needs.
- SC5.2 Version 0 wiring: SoftNPU zone ports on the scrimlet.
- SC5.3 Version 1 NIC dataplane: the mapping from dendrite tables to
  `rte_flow` rules.
- SC5.4 Slow path, punt, and inject.
- SC5.5 Edge control agent: the program on the edge box that receives
  dendrite's calls.
- SC5.6 Edge routing: the edge box's part in C3.

### C6. Identity and trust

Role: give each sled an identity that trust quorum, Nexus, MGS, and
sled-agent agree on.

Requirements:

- C6-R1: Each sled has its own sprockets test certificate set, named in the
  `[sprockets]` table of its `config.toml`.
- C6-R2: The certificate's platform ID (`PDV2:<part>:<rev>:<serial>`) is the
  sled's identity. sled-agent finds a new sled by this ID
  (`find_sprockets_stream`, `platform_id_to_baseboard_id`).
- C6-R3: The sled's own baseboard identity matches its certificate.
  If the SMBIOS manufacturer is `a4x2`, `sled-hardware` reads the identity
  from SMBIOS type 1. Otherwise it uses the hostname as the serial and the
  platform name as the part.
- C6-R4: The sp-sim entry for each sled carries the same serial and part
  numbers (C4-R4).

Known facts:

- voxel generates one numbered certificate set per sled
  (`stage_sprockets` in `voxel/src/topo.rs`) and sets each VM's SMBIOS
  serial to `2FAKE00<n>`.
- The `non-gimlet` sled-agent configuration ships one test certificate set
  for a single sled.

Approach:

- Preferred: rewrite each PC's SMBIOS type 1 strings with the board vendor's
  DMI tool, as voxel does for VMs. This needs no code change.
- Alternative: patch `sled-hardware` to read the identity from a file.

Subcomponents:

- SC6.1 Certificate generation for N sleds.
- SC6.2 Identity alignment on each PC (SMBIOS or patch).
- SC6.3 Identity records for sp-sim and RSS.

### C7. Rack setup and lifecycle

Role: bring the rack up, add and remove sleds, survive reboots, and change
software versions.

Rack setup sequence:

1. Every host boots. Its bootstrap agent advertises a bootstrap prefix
   through C3. The scrimlet starts its switch zone.
2. RSS starts from `config-rss.toml` on the scrimlet, or from wicketd. It
   finds the other sleds and starts trust quorum over sprockets.
3. RSS writes the early network configuration to the bootstore. The
   scrimlet applies it through dendrite and mgd, so the edge box gets its
   uplink address and routes.
4. RSS gives each sled its underlay subnet and starts internal DNS and NTP.
   Boundary NTP reaches the internet through the edge box. RSS waits for
   time synchronization.
5. RSS starts CockroachDB and Nexus and hands the rack to Nexus. Nexus
   programs the NAT entries for its own external addresses and for external
   DNS.

Requirements:

- C7-R1: C3, C4, and C5 work before the first rack setup can finish,
  because steps 3 to 5 depend on them.
- C7-R2: The rack survives a reboot of any one sled without operator action,
  except for instances on that sled.
- C7-R3: An operator can add a sled after rack setup. The new sled needs an
  sp-sim entry, because Nexus lists sleds to add from SP inventory.
- C7-R4: The rack has a documented upgrade path to a later omicron release.

Known facts:

- Nexus-driven updates write host phase 1 through the SP and host phase 2
  to an M.2 boot slot. Then the SP resets the host. sp-sim cannot
  reset a PC, and a PC boots Helios from its own loader.
- The update planner holds all zone updates until SP, root of trust, and
  host OS updates finish (`planner.rs`).
- voxel seeds the release's host images into sp-sim and the M.2 slots, so
  the first release converges.

Approach:

- Version 0 and 1: seed host images as voxel does, and upgrade by
  reinstalling the rack layer or by a MUPdate-style manual procedure.
- Research: a host update adapter. sp-sim's host reset becomes a power cycle
  through the PC's BMC, and the PC's loader boots host phase 2 from the M.2
  boot slot.

Open questions:

- How long does the planner wait on a host OS update that never finishes,
  and what does it report?
- Can a manual procedure upgrade the control plane zones while the host
  images stay at the release that voxel-style seeding wrote?

Subcomponents:

- SC7.1 RSS configuration generation.
- SC7.2 First-boot orchestration across hosts.
- SC7.3 Add and remove a sled.
- SC7.4 Upgrade procedure.
- SC7.5 Host update adapter (research).
- SC7.6 Backup and reinstall.

### C8. Provisioning tooling

Role: build a rack from bare machines with one command per stage, as
homicron does for a single voxel host today.

Requirements:

- C8-R1: One inventory file describes the rack: hosts, MAC addresses, disks
  and their roles, the scrimlet, the edge box, VLANs, and address ranges.
- C8-R2: The tooling installs Helios on each host and applies the sled host
  profile (SC1.1).
- C8-R3: The tooling produces each sled's `config.toml`, `config-rss.toml`,
  certificates, and sp-sim configuration from the inventory.
- C8-R4: The tooling builds or fetches the omicron packages once and
  installs them on every sled.
- C8-R5: The tooling applies the switch configuration (SC2.2).
- C8-R6: Every step is idempotent (safe to run twice), as homicron's steps
  are today.

Known facts:

- `voxel-config` renders sled configuration (`sled.rs`) and RSS
  configuration (`rss_request.rs`) with omicron's own types.
- homicron already installs Helios, adds a user, builds voxel, and applies
  numbered host steps over SSH.

Subcomponents:

- SC8.1 Inventory format.
- SC8.2 Omicron package build or TUF repository fetch.
- SC8.3 Configuration generators, ported from `voxel-config`.
- SC8.4 Install and uninstall stages.
- SC8.5 Switch configuration push.

## 6. Oxide software configuration

### sled-agent `config.toml`, every sled

| Key | Value |
|---|---|
| `deployment` | `custom`, with `sled_mode = "sled"` or `"scrimlet"` and a `switch` table |
| `switch` (scrimlet, version 0) | `kind = "soft_npu_zone"`, with front and rear port counts |
| `data_link`, `data_links` | The underlay link |
| `external_disks` | `kind = "hardcoded"`, with the M.2 and U.2 drives from SC1.2 |
| `[sprockets]` | This sled's certificate set from SC6.1 |
| `switch_zone_maghemite_links` | The `tfport` link of the edge box's underlay port (scrimlet) |
| `vmm_reservoir_percentage` | Sized for instances |
| `skip_timesync` | `false`, except during development |

### `config-rss.toml`, scrimlet

| Key | Value |
|---|---|
| `bootstrap_discovery` | `only_these`, with each sled's bootstrap address |
| `rack_network_config.rack_subnet` | An internal `/56` |
| `rack_network_config.ports` | One uplink port, `qsfp0`, on `switch0` |
| `infra_ip_first`, `infra_ip_last` | The edge box's uplink address |
| `bgp` | Empty for static routing, or the upstream peer |
| `ntp_servers`, `dns_servers` | Outside servers |
| `external_dns_zone_name` | A domain that the home network delegates or overrides |

Nexus runs with the `multi-sled` policy, so Crucible places its three copies
on three sleds.

## 7. What this design loses compared with an Oxide rack

- The hardware root of trust, attestation, and measured boot. Trust quorum
  runs with software test keys.
- SP functions: power control, inventory from real hardware, and firmware
  updates.
- Nexus-driven host OS updates, and therefore unattended upgrades.
- Switch redundancy. The edge box and the underlay switch are single points
  of failure. Traffic between sleds depends only on the underlay switch.
- Line-rate edge traffic in version 0.
- Upstream support. Every omicron release can change an interface that this
  design depends on.

## 8. Risks and unknowns

| # | Risk | Affects | First test |
|---|---|---|---|
| 1 | RSS or Nexus rejects a multi-sled rack with one switch | C4, C7 | Run RSS with one scrimlet in voxel |
| 2 | `sidecar-lite` misroutes with all sleds behind one rear port | C5 | voxel rack with a shared VLAN behind one SoftNPU port |
| 3 | mgd's tunnel origins depend on a transit ddm | C3, C4 | Read mgd's ddm client and trace one origin |
| 4 | Trust quorum rejects PC identities | C6 | Two PCs with rewritten SMBIOS strings |
| 5 | Host OS update blocks zone updates forever | C7 | Upgrade a voxel rack with host images held back |
| 6 | MLD snooping drops link-local multicast | C2, C3 | Packet capture on the switch during discovery |
| 7 | NIC port-range matching needs many rules | C5 | Count rules for a realistic NAT table |
| 8 | Omicron interface churn | All | Pin omicron as voxel does |

voxel can test risks 1, 2, 3, and 5 on one machine, before any hardware
purchase.

## 9. Subcomponent index

| ID | Subcomponent | Depends on | Version |
|---|---|---|---|
| SC1.1 | Sled host profile | none | 0 |
| SC1.2 | Disk role mapping | SC1.1 | 0 |
| SC1.3 | Omicron install on bare metal | SC8.2 | 0 |
| SC2.1 | VLAN, MTU, and port plan | none | 0 |
| SC2.2 | Switch configuration as code | SC2.1 | 0 |
| SC3.1 | Multi-access discovery | none | 0 |
| SC3.2 | Route exchange between servers | SC3.1 | 0 |
| SC3.3 | Route installation and expiry | SC3.2 | 0 |
| SC3.4 | Tunnel origins and OPTE programming | SC3.2 | 0 |
| SC3.5 | Edge box participation | SC3.2, SC5.6 | 0 |
| SC4.1 | dendrite remote backend | SC4.2 | 1 |
| SC4.2 | Edge control protocol | SC5.1 | 1 |
| SC4.3 | Punt link and tfportd source | SC2.1 | 1 |
| SC4.4 | sled-agent switch kind | SC4.1 | 1 |
| SC4.5 | sp-sim fleet configuration | SC6.3 | 0 |
| SC4.6 | uplinkd, mgd, lldpd review | none | 0 |
| SC5.1 | Dataplane feature set | none | 0 |
| SC5.2 | Version 0 SoftNPU wiring | SC2.1 | 0 |
| SC5.3 | Version 1 NIC dataplane | SC5.1 | 1 |
| SC5.4 | Slow path, punt, inject | SC5.1 | 1 |
| SC5.5 | Edge control agent | SC4.2 | 1 |
| SC5.6 | Edge routing | SC3.2 | 0 |
| SC6.1 | Certificate generation | none | 0 |
| SC6.2 | Identity alignment | SC6.1 | 0 |
| SC6.3 | Identity records | SC6.1 | 0 |
| SC7.1 | RSS configuration generation | SC6.3 | 0 |
| SC7.2 | First-boot orchestration | SC7.1 | 0 |
| SC7.3 | Add and remove a sled | SC4.5 | 0 |
| SC7.4 | Upgrade procedure | SC7.2 | 0 |
| SC7.5 | Host update adapter | SC7.4 | research |
| SC7.6 | Backup and reinstall | SC7.2 | 0 |
| SC8.1 | Inventory format | none | 0 |
| SC8.2 | Omicron package build or fetch | none | 0 |
| SC8.3 | Configuration generators | SC8.1 | 0 |
| SC8.4 | Install and uninstall stages | SC8.3 | 0 |
| SC8.5 | Switch configuration push | SC2.2 | 0 |

## Appendix A. Reference build

The reference build is one set of hardware that meets the requirements.

| Role | Hardware | Notes |
|---|---|---|
| Sled | ASRock Rack AM5D4ID2, AMD EPYC 4545P (16 cores), 128 GB, NVMe | `homicron00` is the first one |
| Sled NIC | Chelsio T520-CR, 2 × 10 Gb SFP+ | Geneve offloads under Helios (T5) |
| Underlay switch | MikroTik CRS309-1G-8S+IN | 8 × 10 Gb SFP+ and 1 × 1 Gb, switch chip 98DX8208, 81 Gbps non-blocking, 800 MHz dual-core ARM CPU |
| Edge box, version 0 | The scrimlet sled | SoftNPU zone |
| Edge box, version 1 | Linux machine with NVIDIA ConnectX-6 Dx | DPDK mlx5 |

The CRS309 port budget is one SFP+ port per sled, one for the version 1
edge box, and the 1 Gb port for home. That leaves room for six
or seven sleds. Each T520's second port carries the management VLAN or a
second underlay path.

MikroTik's L3 offload documentation says that the CRS309 routes IPv6 in its
CPU. The CRS309 therefore runs as a layer-2 switch only, which is its default
configuration. Before relying on jumbo frames, read the port's `l2mtu` in
RouterOS.

A Cortex-M development board running Hubris cannot act as an SP for a PC.
Hubris's Gimlet firmware expects Gimlet hardware such as the power sequencer
and host flash.

## Appendix B. Evidence

Sources read on 2026-11-02:

| Repository | Commit | Files |
|---|---|---|
| omicron | `50db5ad` | `docs/how-to-run.adoc`, `docs/networking.adoc`, `sled-agent/src/config.rs`, `sled-agent/src/services.rs`, `sled-agent/src/sled_agent.rs`, `sled-agent/rack-setup/src/service.rs`, `sled-agent/config-reconciler/src/host_phase_2.rs`, `sled-hardware/src/lib.rs`, `sled-hardware/src/illumos/mod.rs`, `nexus/src/app/rack.rs`, `nexus/reconfigurator/planning/src/planner.rs`, `trust-quorum/src/connection_manager.rs`, `dev-tools/xtask/src/virtual_hardware.rs` |
| voxel | `a6ad27b` | `voxel/src/topo.rs`, `voxel-init/src/gimlet.rs`, `voxel-config/src/sled.rs`, `voxel-config/src/config.rs` |
| falcon | `6bfdb16` | `lib/src/lib.rs` |
| softnpu | `a6a8785` | `client/src/bin/softnpu.rs`, `client/src/bin/npuzone.rs` |
| sidecar-lite | `main` | `p4/sidecar-lite.p4`, `p4/headers.p4` |
| maghemite | `main` | `ddm/src/discovery/mod.rs`, `ddm/src/sm/state.rs`, `ddm/src/exchange/runtime.rs`, `ddm/src/sys.rs`, `ddm-protocol/src/v3.rs` |
| opte | `af6eff8` | `xde/src/xde.rs`, `xde/src/mac/mod.rs`, `lib/oxide-vpc/src/api.rs` |
| propolis | `79ae305` | `bin/propolis-standalone/src/config.rs` |
| illumos-gate (`stlouis`) | `7b8fac3` | `usr/src/uts/common/io/cxgbe/t4nex/t4_mac.c`, `common/t4_chip_type.h` |

Outside sources:

- DPDK mlx5 guide: https://doc.dpdk.org/guides/nics/mlx5.html
- Intel E810 switchdev guide:
  https://edc.intel.com/content/www/us/en/design/products/ethernet/appnote-e810-eswitch-switchdev-mode-config-guide/switchdev-mode-tc-flower-hardware-offloads
- MikroTik L3 hardware offloading: https://help.mikrotik.com/docs/x/q4BzB
- MikroTik CRS309-1G-8S+IN: https://mikrotik.com/product/crs309_1g_8s_in
- illumos `mlxcx` man page: https://tribblix.org/man/man4d/mlxcx.html
- AMD Pensando: https://amd.com/en/products/network-interface-cards/pensando.html

## Appendix C. Alternatives considered

| Alternative | Result | Reason |
|---|---|---|
| voxel as it is | Kept as a test bed | Sleds are VMs, and bhyve does not nest, so instances cannot run. voxel tests risks 1, 2, 3, and 5. |
| voxel with a falcon SoftNPU port on a physical link | Possible small step | One physical compute sled joins a VM rack. Useful as a test of C1 and C6. |
| Omicron single-machine mode | Possible today | Real instances on one PC, with no protection across machines. |
| propolis-standalone with Crucible across hosts | Possible today | Disks survive the loss of one host. Failover is manual, and there is no Oxide API. |
| One standalone omicron per host | Rejected | Each control plane manages only its own Crucible copies, all on one machine. |
| The layer-2 switch as transit router | Rejected | The reference switch routes IPv6 in its CPU, and ddm names the transit peer as the next hop. |
| A Tofino switch | Rejected | Oxide's switch software targets the Sidecar, and Intel discontinued Tofino. |
| SoftNPU as an illumos kernel module | Deferred | Removes per-packet system calls, but needs kernel ports of the P4 compiler output. Version 1 hardware offload is the preferred path. |
| Fixed-function switch chips for boundary services | Rejected | They cannot add Oxide's Geneve option or run the NAT-to-Geneve table. |
