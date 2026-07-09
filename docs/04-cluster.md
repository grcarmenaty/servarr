# 04 — Forming the Proxmox Cluster

Three standalone Proxmox installs become one cluster with a shared web
UI, shared configuration, and quorum-based membership (corosync).

## Before you start

- All three nodes installed, updated, `01-post-install.sh` run.
- All nodes can resolve and ping each other by name (`/etc/hosts`).
- Node clocks in sync (`chronyc tracking` → small offset).
- **No VMs exist yet** on node2/node3 — joining a cluster requires the
  joining node to have no guests. Do this before creating anything.

## Create the cluster (on node1 only)

```bash
pvecm create homelab
```

(Or GUI: *Datacenter → Cluster → Create Cluster*.)

Corosync will use node1's management IP as link0. If you built the
dedicated 10.10.10.0/24 network you can instead put corosync on it —
but on a 2-NIC budget it's better to keep corosync on the LAN NIC and
reserve the second NIC for Ceph, so storage floods don't starve the
cluster heartbeat. That's what these docs assume.

## Join node2 and node3

On **node2** (then repeat on node3):

```bash
pvecm add 192.168.1.11
```

- Confirm the fingerprint, enter node1's root password.
- Or GUI: on node1 *Datacenter → Cluster → Join Information → Copy*, then
  on node2 *Datacenter → Cluster → Join Cluster → paste*.

Join nodes **one at a time** — wait for the first join to finish before
starting the second.

## Verify

```bash
pvecm status
```

Expected: `Nodes: 3`, `Quorate: Yes`, all three IPs in the membership
list. The web UI on any node now shows all three under *Datacenter*.

```
Votequorum information
~~~~~~~~~~~~~~~~~~~~~~
Expected votes:   3
Total votes:      3
Quorum:           2
```

## Understanding quorum (read this once, it explains later surprises)

- 2 of 3 votes are required for the cluster to be *quorate*.
- If a node dies, the other two keep working normally. ✔
- If **two** nodes are down, the survivor goes read-only: VMs keep
  running but you can't start/stop/modify anything, and `/etc/pve` is
  locked. That's by design (split-brain prevention).
- Escape hatch in a genuine emergency (single survivor, others truly
  dead): `pvecm expected 1` — temporary, until reboot; understand the
  split-brain risk before using it.
- Never power off two nodes for maintenance at the same time.

## Useful cluster facts

- `/etc/pve` is now a cluster filesystem — files written there (storage
  config, VM configs) replicate to all nodes instantly.
- Any node's web UI manages the whole cluster.
- Root SSH between nodes is now key-authenticated automatically
  (`ssh node2` from node1 just works) — the scripts rely on this.

Next: `docs/05-ceph.md`.
