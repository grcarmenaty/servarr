# 06 — VMs, Live Migration, and High Availability

With the cluster and Ceph in place, this is the payoff: VMs whose disks
live everywhere, move anywhere, and survive a node dying.

## Creating VMs on Ceph

Create VMs as usual (*Create VM* in the GUI) with two deliberate choices:

- **Disk → Storage: `vm-pool`** (the Ceph RBD storage). This is what
  makes migration and HA possible.
- **CPU type**: `host` gives best performance, but if your three scrap
  boxes have different CPU generations (or Intel + AMD mixed), use
  `x86-64-v2-AES` so live migration works between them.

Container templates and ISOs are best kept on `cephfs` storage so
they're visible from every node.

Qemu guest agent: install `qemu-guest-agent` in every Linux VM and
enable it in VM *Options* — clean shutdowns and IP display in the GUI.

## Live migration

With disks on Ceph, migration only copies RAM:

```bash
qm migrate <vmid> node2 --online
```

or right-click the VM → *Migrate*. Migration traffic is pinned to the
10 GbE mesh (`migration:` line in `/etc/pve/datacenter.cfg`, set by
`02-create-cluster.sh`), so even a big-RAM VM moves in seconds.
Use it to empty a node before hardware maintenance:

```bash
# drain node3 (run from any node)
ha-manager crm-command node-maintenance enable node3   # HA-managed guests move off
# migrate remaining non-HA guests by hand, then reboot/fix node3
ha-manager crm-command node-maintenance disable node3
```

## High availability

HA = "if the node running this VM dies, start it on a survivor."
Requires: 3-node quorum ✔ and shared storage ✔ — you have both.

Enable per VM: *Datacenter → HA → Add*, select the VM, request state
`started`. CLI:

```bash
ha-manager add vm:100 --state started
```

What happens when node2 dies:

1. Its HA VMs go down with it (this is restart-HA, not fault-tolerance —
   expect ~2–3 minutes of downtime, not zero).
2. After ~1 minute of lost heartbeat, node2 is fenced (it self-resets via
   watchdog if it's half-alive — this is why HA needs working quorum).
3. The HA manager starts the VMs on node1/node3.

Practical rules:

- Only HA-enable VMs that matter (router-adjacent services, home
  automation…). Every HA VM must fit in the **spare** RAM of the
  surviving nodes — don't HA-protect more RAM than `(total − largest
  node)` can hold.
- Don't HA-enable VMs with local resources (USB devices, PCI
  passthrough, local disks) — they can't start elsewhere.
- Test it once for real: `echo b > /proc/sysrq-trigger` on a node (hard
  reset) and watch *Datacenter → HA* do its thing. Better to learn its
  timing now than during a real failure.

## Backups (Ceph replication is not a backup)

Replication survives hardware death, not `rm -rf`, ransomware in a VM,
or a bad `ceph` command. Set up *Datacenter → Backup* with a schedule to
storage **outside the Ceph pool** — a USB disk on one node, an NFS box,
or (best) a small Proxmox Backup Server VM/host with its datastore on a
non-Ceph disk.

## Suggested layout for a media-server cluster

| Guest | Type | Storage | HA? |
|-------|------|---------|-----|
| AdGuard, Caddy, WireGuard, Uptime Kuma (`docs/09`) | LXC ×4 | vm-pool | yes |
| Home Assistant OS (`docs/09`) | VM | vm-pool | yes |
| **servarr VM** — Jellyfin + *arrs + downloader (`docs/08`) | VM | vm-pool (root + media data disk) | yes |
| Playground / test VMs | VM | vm-pool | no |

The whole media stack — server, *arrs, downloads, and the library
itself — lives in the servarr VM on Ceph-backed disks, so any node can
run it and HA moves it freely. Everything above is created by scripts
`10`–`13`.

## Cluster-wide HA policy

`scripts/20-enable-ha.sh` enrolls **every** guest into HA and adds
anti-affinity rules so the redundant pairs never share a node. What
"highly available" then actually means, per service:

| Service | Redundancy | Node dies → outage |
|---------|-----------|--------------------|
| Nextcloud app tier | 2 instances, ≠ nodes, load-balanced | **none** (seconds of health-check lag) |
| DNS (AdGuard ×2) | 2 instances, ≠ nodes, both in DHCP | **none** (clients use the second resolver) |
| Ceph storage | 3-way replication | none (degraded until healed) |
| Proxmox cluster | 3-node quorum | none |
| cloud-data (DB/NFS) | HA restart | ~2–3 min (Nextcloud stalls, resumes) |
| Jellyfin / *arrs / HAOS | HA restart | ~2–3 min |
| Caddy, WireGuard, Kuma, ntfy, Forgejo | HA restart | ~1–2 min (LXCs restart fast) |
| Wazuh, AI assistant | **manual restart** (HA opt-out, docs/06 capacity) | down until you start it on a survivor (minutes) — flip `HA_ENROLL_*` after adding RAM |
| desktop VMs / AI VM *with* GPU | none — pinned by PCI passthrough | down until their node returns (docs/15/16) |

The restart tier is a genuine limit of single-instance software, not of
the cluster: Jellyfin, Home Assistant, and Postgres can't run
active-active without heavyweight machinery. A self-healing ~2-minute
restart with zero human involvement is the honest ceiling — and testing
it (hard-reset a node, watch it recover) is what turns "should work"
into "guaranteed".

### Capacity — the cluster is now full, and that's a decision, not a bug

Two surviving nodes offer roughly **~80 GB** of guest RAM (192 GB raw −
64 GB for the dead node, minus ~24 GB each for Ceph OSDs + Proxmox on
the two survivors). If we HA-protected **everything**:

```
servarr 16 + cloud tier 24 (cloud-data 16 + cloud1/2 8) + photos 8
+ wazuh 8 + ai 12 + HAOS 4 + LXCs ~6  ≈  78 GB
```

78 against 80 is **not safe** — one bad estimate or one growing VM and a
node failure can't be absorbed. So the policy, encoded in `cluster.env`
and honored by `20-enable-ha.sh`:

- **Always HA** (must survive, or is cheap): the two Nextcloud apps, both
  AdGuards, cloud-data, servarr, photos, HAOS, all the LXCs.
- **HA opt-out by default** (`HA_ENROLL_WAZUH=no`, `HA_ENROLL_AI=no`):
  Wazuh (8 GB) and the AI VM (12 GB). Both self-restart cleanly on a
  planned move and neither is life-or-death if it's down for the few
  minutes it takes you to start it by hand on a survivor. Leaving them
  out drops the HA set to **~58 GB — comfortable** against 80.
- **Can't be HA** (node-pinned by passthrough, or disposable): GPU-
  attached AI VM, desktop VMs from `scripts/30`.

**To HA everything anyway, add RAM.** 128 GB/node makes the whole set
fit with room; flip both `HA_ENROLL_*` flags to `yes` and re-run
`20-enable-ha.sh`. Until then, recheck this arithmetic before
HA-protecting anything new — the platform has grown into its hardware.
