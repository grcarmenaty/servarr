# 02 — Network Plan

Decide all addressing **before** installing anything. Changing IPs after
the cluster and Ceph exist is painful.

## Address plan (reference — adjust to your LAN)

| Purpose | Subnet | node1 | node2 | node3 |
|---------|--------|-------|-------|-------|
| Management + VMs (`vmbr0`) | 192.168.1.0/24 | 192.168.1.11 | 192.168.1.12 | 192.168.1.13 |
| Ceph public+cluster (2nd NIC) | 10.10.10.0/24 | 10.10.10.11 | 10.10.10.12 | 10.10.10.13 |

- Management IPs must be **static** (set in the installer, or reserve in
  your router's DHCP at minimum — static is better).
- The Ceph subnet needs no gateway and no DHCP; it's point-to-point
  between the three nodes via a dedicated switch.
- Hostnames: `node1`, `node2`, `node3` (or whatever you like — but pick
  final names now; renaming a clustered Proxmox node is miserable).

Everything below assumes this plan; `scripts/cluster.env` is where you
record your real values.

## /etc/network/interfaces — two-NIC layout

Proxmox manages networking through `/etc/network/interfaces` (ifupdown2).
Example for node1 with onboard NIC `enp3s0` (LAN) and PCIe NIC `enp1s0`
(Ceph):

```
auto lo
iface lo inet loopback

# --- LAN / VM bridge ---
iface enp3s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.11/24
    gateway 192.168.1.1
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0

# --- Dedicated Ceph network ---
auto enp1s0
iface enp1s0 inet static
    address 10.10.10.11/24
    mtu 9000
```

Notes:

- The installer creates `vmbr0` for you; you only add the Ceph interface
  stanza afterwards (GUI: *System → Network → Create → no bridge needed,
  plain interface with IP*).
- `mtu 9000` (jumbo frames) helps Ceph on gigabit — but only if the Ceph
  switch supports it and **all three nodes** set it. If unsure, leave MTU
  at default; a mismatched MTU causes bizarre stalls.
- Interface names (`enpXsY`) differ per machine — check with `ip -br link`.
- Apply changes with `ifreload -a` (or reboot).

Single-NIC nodes: skip the second stanza entirely; Ceph will use the LAN
subnet.

## /etc/hosts — on every node

Corosync and Ceph both resolve peer names constantly; don't depend on
external DNS. Every node's `/etc/hosts` should contain all three nodes:

```
127.0.0.1 localhost
192.168.1.11 node1.home.lan node1
192.168.1.12 node2.home.lan node2
192.168.1.13 node3.home.lan node3
```

The Proxmox installer writes only the local node's entry — add the other
two on each machine (or run `scripts/01-post-install.sh`, which does it
from `cluster.env`).

## Verification checklist

From **each** node:

```bash
ping -c2 192.168.1.11 && ping -c2 192.168.1.12 && ping -c2 192.168.1.13   # LAN
ping -c2 10.10.10.11 && ping -c2 10.10.10.12 && ping -c2 10.10.10.13      # Ceph net
ping -c2 -M do -s 8972 10.10.10.12    # only if you enabled MTU 9000
getent hosts node1 node2 node3        # names resolve via /etc/hosts
```

All green → proceed to the Proxmox install doc.
