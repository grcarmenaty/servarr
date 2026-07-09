# 01 — Hardware Requirements (Scrap Edition)

Ceph was designed for datacenters, but a 3-node cluster runs fine on old
desktops and workstations **if** you respect a few hard requirements.
This page tells you what actually matters and what you can cheap out on.

## Per-node minimums

| Component | Bare minimum | Comfortable | Notes |
|-----------|-------------|-------------|-------|
| CPU | 4 threads, x86-64 with VT-x/AMD-V | 8+ threads | Virtualization extensions are **mandatory** — enable in BIOS |
| RAM | 8 GB | 16–32 GB | See RAM budget below — this is the #1 constraint on scrap hardware |
| OS disk | 32 GB SSD | 120 GB+ SSD | Small SATA/NVMe SSD. Avoid installing Proxmox on a USB stick — it will die |
| Ceph OSD disk(s) | 1 dedicated disk | 1–2 SSDs or HDDs | Whole disk given to Ceph, **separate from the OS disk** |
| NIC | 1× 1 GbE | 2× 1 GbE (or 2.5/10 GbE) | Second NIC for Ceph traffic is the biggest upgrade you can make |

## RAM budget — do this math for each node

Ceph and Proxmox both eat RAM before your VMs get any:

```
Proxmox VE base            ~1.5 GB
Ceph MON + MGR             ~1.5 GB
Each OSD (default target)  ~4.0 GB   (tunable down to ~2 GB, see below)
────────────────────────────────────
Overhead with 1 OSD        ~7 GB
Remaining on a 16 GB node  ~9 GB for VMs
```

On 8 GB nodes it works but is tight: lower the OSD memory target and run
lightweight VMs/containers only. In `/etc/ceph/ceph.conf` (or via
`ceph config set`):

```
ceph config set osd osd_memory_target 2147483648   # 2 GB per OSD
```

Don't go below 2 GB — OSDs get slow and flappy.

## Disks

- **One OS disk + at least one OSD disk per node.** Ceph takes the whole
  OSD disk; it can't share with the OS.
- **SSDs vastly outperform HDDs for Ceph**, even old SATA ones. A used
  256–512 GB SSD per node is the sweet spot for VM disks.
- HDDs are fine for bulk media storage (a second pool or CephFS), painful
  for VM root disks.
- **Avoid SMR drives** (many cheap 2.5" HDDs are SMR). Ceph's write
  pattern makes them crawl and drop out of the cluster.
- **Avoid hardware RAID for OSD disks.** Ceph wants raw disks. If the
  machine has a RAID controller, flash it to IT/HBA mode or configure
  each disk as a single-drive RAID0 as a last resort.
- Consumer SSDs without power-loss protection lie about sync writes;
  they work, just don't expect enterprise latency numbers.

Symmetry matters: Ceph balances by capacity, so wildly different disk
sizes across nodes means the smallest node's disk fills first and caps
usable space. Roughly-equal capacity per node is ideal.

## Usable capacity math

With 3-way replication (the only safe choice at this scale):

```
usable ≈ (smallest node's OSD capacity) × safety margin
```

Example: 3 nodes × 1 TB OSD each = 3 TB raw → **1 TB replicated**, of
which you should use at most **~700 GB** so Ceph has room to recover when
a disk fails.

## Network

- All three nodes on the same L2 segment (same switch/VLAN).
- **Two NICs per node is the goal**: one for LAN/VM traffic, one for a
  dedicated Ceph network on its own switch (a dumb 5-port gigabit switch
  for ~15€ is enough). Ceph replication multiplies traffic ×3; on a
  shared 1 GbE link it will fight your VMs.
- Old PCIe gigabit NICs (Intel i210/i350, even PRO/1000) are ideal scrap
  finds and better supported than most onboard Realtek chips.
- One NIC total? It works — just expect storage and VM traffic to
  contend. Configure it all on `vmbr0` and set the Ceph network to the
  LAN subnet.

## Miscellaneous scrap-hardware gotchas

- **BIOS settings**: enable VT-x/AMD-V and VT-d/IOMMU (if present);
  disable secure boot if the installer complains; set "restore power on
  AC loss" so nodes come back after an outage.
- **Time**: dead CMOS batteries cause clock skew, and Ceph monitors are
  extremely sensitive to it. Replace CR2032s (cheapest cluster component
  you'll buy) — chrony handles the rest once booted.
- **Mixed CPU vendors** (Intel + AMD nodes) are fine for the cluster, but
  live migration between vendors requires the VM CPU type set to
  `x86-64-v2-AES` (or `kvm64`) instead of `host`.
