# 00 — This Cluster: Concrete Build Plan

The generic docs (01–07) explain the *why*; this page is the actual plan
for our hardware.

## Node inventory (×3, identical or near-identical)

| Component | Spec | Verdict |
|-----------|------|---------|
| CPU | Ryzen 7 class (8c/16t) | Plenty. Use CPU type `host` if all three are Ryzen; `x86-64-v2-AES` if vendors/generations are mixed |
| RAM | 64 GB | Comfortable — default Ceph memory tuning, no compromises |
| NICs | 2× 10 GbE + 1× 1 GbE | 1 GbE → LAN/internet; 2× 10 GbE → **full-mesh Ceph network** (no 10G switch needed) |
| Disks | 2× 3 TB + 4× 1 TB | 1× 1 TB = OS disk, remaining 5 = OSDs |

## Disk layout (per node)

| Disk | Role |
|------|------|
| 1 TB #1 | Proxmox OS (installer target, ext4/LVM) — if one of the 1 TB disks is an SSD, use *that* one here |
| 1 TB #2–#4 | Ceph OSDs |
| 3 TB #1–#2 | Ceph OSDs |

→ **5 OSDs per node, 15 OSDs total.** Mixed 1 TB / 3 TB OSDs are fine —
CRUSH weights each disk by capacity automatically.

If some of the 1 TB disks turn out to be **SSDs**, upgrade the plan:

- Keep them as separate OSDs and split pools by device class
  (`docs/05-ceph.md` §5): `vm-pool` on SSD, `media-pool` on HDD.
- Or dedicate one SSD per node as DB/WAL device for the 3 TB HDDs
  (`pveceph osd create /dev/sdX --db_dev ...`) — big HDD latency win.

Check with `cat /sys/block/sdX/queue/rotational` (1 = HDD, 0 = SSD) or
`lsblk -o NAME,SIZE,ROTA,MODEL`.

## Capacity math

```
Per node raw:      2×3 TB + 3×1 TB     =  9 TB
Cluster raw:       3 × 9 TB            = 27 TB
Usable (size=3):   27 / 3              =  9 TB
Safe working set:  9 × 0.7             ≈  6.3 TB
```

~6 TB of triple-replicated storage for VMs + media library. If the media
collection outgrows that, options later: erasure-coded CephFS data pool
for media (2× overhead instead of 3×), or bigger 3.5" disks in the same
bays.

## RAM budget (per node)

```
Proxmox VE base                ~1.5 GB
Ceph MON + MGR (+MDS)          ~2   GB
5 OSDs × 4 GB default target   ~20  GB
────────────────────────────────────
Overhead                       ~24  GB
Available for VMs/containers   ~40  GB
```

Leave `OSD_MEMORY_TARGET` empty in `cluster.env` (keep the 4 GB
default — the page cache it buys matters on HDD OSDs). HA planning: a
dead node's HA guests must fit in the survivors' headroom, so keep
HA-protected guests under ~40 GB RAM total cluster-wide (2×40 available,
but you want slack).

## Network assignment

| Interface | Network | Purpose |
|-----------|---------|---------|
| 1 GbE | 10.0.0.0/24 (LAN) | `vmbr0`: management UI, VM/container traffic, internet, corosync **link0** |
| 10 GbE port X | 10.10.10.0/24 (mesh) | direct cable to the *next* node |
| 10 GbE port Y | 10.10.10.0/24 (mesh) | direct cable to the *previous* node |

The two 10 GbE ports form a **routed full mesh** — three DAC/Cat6a
cables, no switch: Ceph public network, corosync **link1** (backup
heartbeat), and the live-migration network all ride on it. Full details
and the exact cabling table: `docs/02-network.md`.

| Cable | From | To |
|-------|------|----|
| 1 | node1 port X | node2 port Y |
| 2 | node2 port X | node3 port Y |
| 3 | node3 port X | node1 port Y |

## Addressing

| Node | LAN (1 GbE, vmbr0) | Ceph mesh (10 GbE) |
|------|--------------------|--------------------|
| node1 | 10.0.0.11 | 10.10.10.11 |
| node2 | 10.0.0.12 | 10.10.10.12 |
| node3 | 10.0.0.13 | 10.10.10.13 |

(Adjust the LAN side to your actual subnet; keep it in `scripts/cluster.env`.)

## Build sequence for this cluster

1. Identify disks and NICs on each node (`lsblk`, `ip -br link`,
   `ethtool <if> | grep Speed`).
2. Install Proxmox on the chosen 1 TB per node → `docs/03-proxmox-install.md`.
3. `scripts/01-post-install.sh` on every node.
4. Cable the mesh, then `scripts/00-ceph-mesh-network.sh <portX> <portY>`
   on every node → `docs/02-network.md`.
5. `scripts/02-create-cluster.sh` (create on node1, join on 2/3).
6. `scripts/03-setup-ceph.sh` (install everywhere, init on node1, mon everywhere).
7. `scripts/04-create-osds.sh` × 5 disks per node.
8. `scripts/05-create-pools.sh` once.
9. `scripts/99-health-check.sh` → HEALTH_OK → start building VMs
   (`docs/06-ha-and-vms.md`).
