# 02 — Network Plan

Three networks, three jobs:

| Network | Interface | Carries |
|---------|-----------|---------|
| LAN 10.0.0.0/24 | 1 GbE → `vmbr0` | web UI, SSH, VM/container traffic, internet, corosync link0 |
| Ceph mesh 10.10.10.0/24 | 2× 10 GbE, direct cables | Ceph public+replication, live migration, corosync link1 |
| (no third network) | — | — |

Decide all addressing **before** installing anything; changing IPs after
the cluster and Ceph exist is painful. Record your real values in
`scripts/cluster.env`.

## Address plan

| Node | Hostname | LAN (vmbr0) | Ceph mesh |
|------|----------|-------------|-----------|
| node1 | node1.home.lan | 10.0.0.11 | 10.10.10.11 |
| node2 | node2.home.lan | 10.0.0.12 | 10.10.10.12 |
| node3 | node3.home.lan | 10.0.0.13 | 10.10.10.13 |

- LAN IPs must be **static** (set in the installer).
- The mesh subnet has no gateway, no DHCP, no switch — it exists only on
  the three cables.
- Pick final hostnames now; renaming a clustered node is miserable.

## The 10 GbE full mesh (no switch required)

With 3 nodes × 2 ports, each node connects directly to both others —
a triangle of three cables (DAC/SFP+ or Cat6a depending on your NICs).
Every node reaches every other node over a dedicated point-to-point
10 Gb link. This is the standard Proxmox "full mesh Ceph" topology and
it saves you a 10G switch entirely.

Pick a convention and physically label the ports: on every node, **port X
goes to the next node, port Y to the previous one** (wrap around):

```
        node1
       X ↓  ↑ Y
node2 Y ←──┘└──→ node3 X   …i.e.:  node1:X→node2:Y,  node2:X→node3:Y,  node3:X→node1:Y
```

### Routed setup (simple)

Both 10 GbE ports get the node's *same* mesh address, plus a host route
per peer out of the right port. Example for **node1** (ports `enp1s0f0` =
X → node2, `enp1s0f1` = Y → node3):

```
auto enp1s0f0
iface enp1s0f0 inet static
    address 10.10.10.11/24
    mtu 9000
    up ip route add 10.10.10.12/32 dev enp1s0f0
    down ip route del 10.10.10.12/32

auto enp1s0f1
iface enp1s0f1 inet static
    address 10.10.10.11/24
    mtu 9000
    up ip route add 10.10.10.13/32 dev enp1s0f1
    down ip route del 10.10.10.13/32
```

`scripts/00-ceph-mesh-network.sh <portX> <portY>` generates and applies
exactly this for whichever node it runs on, using the IPs from
`cluster.env`. Find your port names with:

```bash
ip -br link                       # all interfaces
ethtool enp1s0f0 | grep Speed     # confirm which are the 10G ports
```

Notes:

- **MTU 9000** is safe here — the links are point-to-point and the
  script sets both ends identically. It's a real throughput win for
  Ceph.
- Limitation of the simple routed variant: if one cable/NIC port dies,
  traffic does **not** reroute through the third node — that pair just
  loses its 10G path (Ceph stays up but degraded; corosync falls back to
  link0 on the LAN). The fancier FRR/OpenFabric "routed with fallback"
  variant from the Proxmox wiki fixes this; start simple, upgrade later
  if you ever care.

### Alternative: you own a 10G switch

Skip the mesh: connect one 10G port per node to the switch, give it the
10.10.10.x/24 address directly, done (optionally LACP-bond both ports).
Everything else in these docs is identical — same subnet, same scripts
except `00-ceph-mesh-network.sh` (write the plain static stanza instead).

## vmbr0 — the 1 GbE LAN bridge

The installer creates this from the NIC you select during install (pick
the **1 GbE**, not a 10G port):

```
iface enp3s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 10.0.0.11/24
    gateway 10.0.0.254
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
```

All VMs/containers attach to `vmbr0`. (VM-to-VM traffic between nodes
crosses the 1 GbE LAN; if some day two VMs need 10G between them, a
second bridge on the mesh ports is possible — not worth the complexity
now.)

## What rides on which link

- **Corosync**: link0 = LAN, link1 = mesh (configured by
  `scripts/02-create-cluster.sh`). Two independent heartbeat paths means
  a flooded or failed link never costs you quorum.
- **Ceph public network** = 10.10.10.0/24 (set at `pveceph init`). With
  only 3 nodes there's no benefit splitting a separate cluster network.
- **Live migration** over the mesh: `02-create-cluster.sh` sets
  `migration: secure,network=10.10.10.0/24` in
  `/etc/pve/datacenter.cfg` — 10× faster VM moves than over the LAN.

## /etc/hosts — on every node

Corosync and Ceph resolve peer names constantly; don't depend on
external DNS. `01-post-install.sh` writes this from `cluster.env`:

```
127.0.0.1 localhost
10.0.0.11 node1.home.lan node1
10.0.0.12 node2.home.lan node2
10.0.0.13 node3.home.lan node3
```

## Verification checklist

From **each** node, after cabling and running the mesh script:

```bash
# LAN
ping -c2 10.0.0.11 && ping -c2 10.0.0.12 && ping -c2 10.0.0.13
# mesh — both peers, each via its own cable
ping -c2 10.10.10.11 && ping -c2 10.10.10.12 && ping -c2 10.10.10.13
# jumbo frames actually pass (8972 = 9000 - 28 header)
ping -c2 -M do -s 8972 10.10.10.12 && ping -c2 -M do -s 8972 10.10.10.13
# names resolve locally
getent hosts node1 node2 node3
# raw 10G throughput (optional): iperf3 -s on one node, then
iperf3 -c 10.10.10.12    # expect ~9.4 Gbit/s
```

All green on all three nodes → `docs/04-cluster.md`.
