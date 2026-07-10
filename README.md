# Servarr — 3-Node Proxmox + Ceph Home Server

Infrastructure documentation and setup scripts for a 3-node hyperconverged
home server cluster built from salvaged/scrap hardware, running
**Proxmox VE** with **Ceph** as shared storage.

> **Building it? Start with [`RUNBOOK.md`](RUNBOOK.md)** — the complete
> step-by-step from bare metal to every service running, with exact
> installer parameters and a checkpoint after every phase. The `docs/`
> pages are the per-topic deep dives it links into.

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

3 nodes — each 64 GB RAM, Ryzen 7 class, 2× 3 TB + 4× 1 TB disks,
2× 10 GbE + 1× 1 GbE. The two 10 GbE ports form a switchless **full
mesh** (three direct cables) carrying all Ceph and migration traffic;
the 1 GbE carries LAN/internet/VM traffic.

```
                     ┌──────────────┐
                     │  Router/LAN  │ 10.0.0.0/24
                     └──────┬───────┘ (1 GbE per node)
           ┌────────────────┼────────────────┐
           │                │                │
     ┌─────┴─────┐    ┌─────┴─────┐    ┌─────┴─────┐
     │   node1   │    │   node2   │    │   node3   │
     │ 10.0.0.11 │    │ 10.0.0.12 │    │ 10.0.0.13 │
     │ mon+mgr   │    │ mon+mgr   │    │ mon+mgr   │
     │ 5× osd    │    │ 5× osd    │    │ 5× osd    │
     └──┬─────┬──┘    └──┬─────┬──┘    └──┬─────┬──┘
        │     └──────────┤     └──────────┤     │
        │   10.10.10.0/24│  full mesh,    │     │
        └────────────────┴──2×10GbE ──────┴─────┘
                            per node, no switch
```

Every node runs the full stack: Proxmox VE hypervisor, a Ceph monitor, a
Ceph manager, and five OSDs (one per data disk). Raw 27 TB → ~9 TB
triple-replicated, ~6.3 TB safe working set.

## Repository layout

| Path | Contents |
|------|----------|
| `RUNBOOK.md` | **The full build, step by step, with checkpoints — start here** |
| `docs/00-this-cluster.md` | The concrete hardware/network/capacity plan behind the runbook |
| `docs/01-hardware.md` | General hardware guidance for scrap/salvage builds (reference) |
| `docs/02-network.md` | IP plan, `vmbr0`, the 10 GbE full-mesh Ceph network, `/etc/network/interfaces` examples |
| `docs/03-proxmox-install.md` | Installing Proxmox VE on each node, post-install steps |
| `docs/04-cluster.md` | Forming the 3-node Proxmox cluster |
| `docs/05-ceph.md` | Installing Ceph, monitors, OSDs, pools, CephFS |
| `docs/06-ha-and-vms.md` | VM storage, live migration, high availability |
| `docs/07-troubleshooting.md` | Common failure modes on small/old hardware |
| `docs/08-servarr-stack.md` | Deploying the media stack (Jellyfin + *arrs) on the cluster |
| `docs/09-core-services.md` | DNS, reverse proxy, VPN, monitoring, smart home, backups, UPS |
| `docs/10-cloud-stack.md` | Load-balanced 2×Nextcloud, Firefly III, Paperless-ngx |
| `docs/11-photos.md` | Immich photo backup VM |
| `docs/12-software-catalog.md` | Full software inventory: licenses, repos, links, FOSS audit |
| `docs/13-security-and-network-monitoring.md` | Threat model, hardening, firewall, traffic monitoring |
| `docs/14-wazuh-siem.md` | Wazuh SIEM: agents everywhere, FIM, CVE + CIS scanning |
| `docs/15-remote-desktops.md` | Dynamic desktop VMs + Guacamole browser portal |
| `docs/16-ai-assistant.md` | GPU passthrough, Ollama + Open WebUI authenticated AI endpoint |
| `scripts/cluster.env` | Single config file — edit this first |
| `scripts/*.sh` | Setup scripts, numbered in execution order |
| `scripts/core/` | Provisioning scripts + configs for the core service LXCs |
| `servarr/` | Docker Compose stack + bootstrap for the media VM |
| `cloud/` | Compose stacks for the cloud tier (`data/` + `app/` × 2 VMs) |
| `photos/` | Bootstrap for the Immich VM (fetches Immich's official compose) |
| `wazuh/` | Bootstrap for the Wazuh VM (official single-node deployment) |
| `ai/` | Compose + bootstrap for the GPU AI VM (Ollama + Open WebUI) |

## Setup order

1. Read `docs/00-this-cluster.md` — the disk/NIC/IP plan for this build.
2. Adjust `scripts/cluster.env` (LAN IPs to your subnet).
3. Install Proxmox VE on all 3 nodes (`docs/03-proxmox-install.md`), then
   run `scripts/01-post-install.sh` on **each** node.
4. Cable the 10 GbE mesh triangle and run
   `scripts/00-ceph-mesh-network.sh` on each node (`docs/02-network.md`).
5. Form the cluster (`docs/04-cluster.md` / `scripts/02-create-cluster.sh`).
6. Set up Ceph (`docs/05-ceph.md` / scripts `03`–`05`).
7. Configure HA and create your first VMs (`docs/06-ha-and-vms.md`).
8. Deploy the media stack (`docs/08-servarr-stack.md` /
   `scripts/10-create-servarr-vm.sh` + `servarr/`).
9. Deploy the core services — DNS, proxy, VPN, monitoring, smart home
   (`docs/09-core-services.md` / scripts `11`–`12`) — and set up
   backups + UPS per the same doc.
10. Deploy the cloud tier — two load-balanced Nextcloud instances,
    Firefly III, Paperless-ngx, shared media folder
    (`docs/10-cloud-stack.md` / `scripts/13` + `cloud/`).
11. Deploy Immich photos (`docs/11-photos.md` / `scripts/14` +
    `photos/`).
12. `bash scripts/20-enable-ha.sh` — HA-enroll everything, with
    anti-affinity for the Nextcloud and DNS pairs (`docs/06`).
13. Harden + monitor: scripts `21`–`23` — fail2ban, cluster firewall,
    ntopng traffic monitoring (`docs/13`).
14. Wazuh SIEM + agents everywhere (`docs/14` / scripts `15` + `25` +
    `wazuh/`).
15. Verify with `scripts/99-health-check.sh` at any point. Desktop VMs
    on demand anytime: `scripts/30-create-desktop-vm.sh` (`docs/15`).

## Golden rules for a 3-node Ceph homelab

- **Never** use `size=2, min_size=1` pools to "save space" — that is how
  data gets silently corrupted. Stay on `size=3, min_size=2`.
- **Never** reboot two nodes at once. One at a time, wait for
  `ceph -s` → `HEALTH_OK` between reboots.
- Keep VM disk usage under ~70% of raw-capacity/3 — Ceph needs headroom
  to re-replicate when a disk or node dies.
