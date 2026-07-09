# Servarr — 3-Node Proxmox + Ceph Home Server

Infrastructure documentation and setup scripts for a 3-node hyperconverged
home server cluster built from salvaged/scrap hardware, running
**Proxmox VE** with **Ceph** as shared storage.

## Why this architecture

With exactly 3 nodes you get the smallest cluster that is actually a real
cluster:

- **Quorum** — 3 votes means any single node can die and the cluster keeps
  running (2/3 majority survives).
- **Ceph 3-way replication** — every block of data lives on all 3 nodes.
  Lose a node, lose nothing.
- **High availability** — VMs on a dead node restart automatically on a
  survivor, because their disks are on Ceph, not on the dead node.
- **Live migration** — move running VMs between nodes with no downtime.

## Cluster topology

```
                        ┌──────────────┐
                        │  Router/LAN  │
                        │ 192.168.1.0/24
                        └──────┬───────┘
              ┌────────────────┼────────────────┐
              │                │                │
        ┌─────┴─────┐    ┌─────┴─────┐    ┌─────┴─────┐
        │   node1   │    │   node2   │    │   node3   │
        │ .1.11     │    │ .1.12     │    │ .1.13     │
        │           │    │           │    │           │
        │ mon+mgr   │    │ mon+mgr   │    │ mon+mgr   │
        │ osd(s)    │    │ osd(s)    │    │ osd(s)    │
        └─────┬─────┘    └─────┬─────┘    └─────┬─────┘
              │                │                │
              └────────────────┼────────────────┘
                        ┌──────┴───────┐
                        │ Ceph network │  (dedicated NIC/switch
                        │ 10.10.10.0/24│   if you have one)
                        └──────────────┘
```

Every node runs the full stack: Proxmox VE hypervisor, a Ceph monitor, a
Ceph manager, and one or more OSDs (one per data disk).

## Repository layout

| Path | Contents |
|------|----------|
| `docs/01-hardware.md` | What your scrap hardware needs to have (and workarounds when it doesn't) |
| `docs/02-network.md` | IP plan, bridges, dedicated Ceph network, `/etc/network/interfaces` examples |
| `docs/03-proxmox-install.md` | Installing Proxmox VE on each node, post-install steps |
| `docs/04-cluster.md` | Forming the 3-node Proxmox cluster |
| `docs/05-ceph.md` | Installing Ceph, monitors, OSDs, pools, CephFS |
| `docs/06-ha-and-vms.md` | VM storage, live migration, high availability |
| `docs/07-troubleshooting.md` | Common failure modes on small/old hardware |
| `scripts/cluster.env` | Single config file — edit this first |
| `scripts/*.sh` | Setup scripts, numbered in execution order |

## Setup order

1. Read `docs/01-hardware.md`, inventory your 3 machines, pick disks.
2. Plan addressing per `docs/02-network.md`, then edit `scripts/cluster.env`.
3. Install Proxmox VE on all 3 nodes (`docs/03-proxmox-install.md`), then
   run `scripts/01-post-install.sh` on **each** node.
4. Form the cluster (`docs/04-cluster.md` / `scripts/02-create-cluster.sh`).
5. Set up Ceph (`docs/05-ceph.md` / scripts `03`–`05`).
6. Configure HA and create your first VMs (`docs/06-ha-and-vms.md`).
7. Verify with `scripts/99-health-check.sh` at any point.

## Golden rules for a 3-node Ceph homelab

- **Never** use `size=2, min_size=1` pools to "save space" — that is how
  data gets silently corrupted. Stay on `size=3, min_size=2`.
- **Never** reboot two nodes at once. One at a time, wait for
  `ceph -s` → `HEALTH_OK` between reboots.
- Give Ceph its own NIC if you physically can. It is the single biggest
  performance win on old hardware.
- Keep VM disk usage under ~70% of raw-capacity/3 — Ceph needs headroom
  to re-replicate when a disk or node dies.
