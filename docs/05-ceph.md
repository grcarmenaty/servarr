# 05 — Ceph Setup

Proxmox ships first-class Ceph tooling (`pveceph`), so you never touch
`cephadm`. Target release: whatever your PVE version defaults to
(Squid 19.x on PVE 9) — keep all nodes on the same release.

Ceph roles in this cluster:

| Role | Count | Where | Purpose |
|------|-------|-------|---------|
| MON (monitor) | 3 | one per node | cluster map + quorum; 3 is the correct number, never 2 |
| MGR (manager) | 3 (1 active) | one per node | metrics, dashboard, balancing |
| OSD | 1 per data disk | every node | actually stores data |
| MDS | 3 (1 active) | one per node | only needed for CephFS |

## 1. Install Ceph packages (every node)

```bash
pveceph install --repository no-subscription
```

Or run `scripts/03-setup-ceph.sh install` on each node.
GUI equivalent: *node → Ceph → Install Ceph → No-Subscription*.

## 2. Initialize (node1 only)

```bash
pveceph init --network 10.10.10.0/24
```

`--network` is the Ceph **public network** — the subnet OSDs and clients
talk on: the 10 GbE mesh. Both client I/O and replication ride it; with
only 3 nodes there's nothing to gain from splitting off a separate
`--cluster-network`, and the mesh has the bandwidth for both.

## 3. Monitors and managers (one per node)

```bash
# on node1, then node2, then node3:
pveceph mon create
pveceph mgr create
```

Verify: `ceph -s` shows `mon: 3 daemons`, `mgr: ... standbys: 2`, and
`HEALTH_OK` (or `HEALTH_WARN: no osds` — fine for now).

## 4. OSDs — one per data disk (every node)

The disk must be empty and unpartitioned. **Triple-check the device
name** (`lsblk`) — the wipe is irreversible:

```bash
# wipe leftover partitions/filesystems (e.g. old Windows install)
ceph-volume lvm zap /dev/sdb --destroy

# create the OSD
pveceph osd create /dev/sdb
```

Repeat per disk, per node — or use `scripts/04-create-osds.sh /dev/sdb`.

Options worth knowing:

- Mixed disks: put an HDD's metadata/WAL on a spare SSD partition with
  `--db_dev` for a large speedup:
  `pveceph osd create /dev/sdb --db_dev /dev/sda4`
- Ceph auto-detects HDD vs SSD and records it as the OSD's *device
  class* — useful below.

Verify: `ceph osd tree` shows all OSDs `up` and `in`, spread across the
three hosts.

### Low-RAM nodes (≤ 8–16 GB)

```bash
ceph config set osd osd_memory_target 2147483648   # 2 GiB per OSD
```

## 5. Pools

Create one RBD pool for VM disks (on any node):

```bash
pveceph pool create vm-pool --add_storages
```

- `--add_storages` registers it as Proxmox storage (`vm-pool`) on all
  nodes, ready for VM disks — nothing else needed.
- Defaults are `size=3, min_size=2`: 3 copies, cluster keeps serving I/O
  with 2. **Do not lower these.** `size=2` risks data loss on the first
  bad disk; `min_size=1` nearly guarantees eventual corruption.
- The `pg_autoscaler` is on by default and sizes placement groups for
  you. Leave it alone.

If you have both SSD and HDD OSDs, split them into two pools with CRUSH
device-class rules — fast pool for VM disks, bulk pool for media:

```bash
ceph osd crush rule create-replicated fast default host ssd
ceph osd crush rule create-replicated bulk default host hdd
pveceph pool create vm-pool    --crush_rule fast --add_storages
pveceph pool create media-pool --crush_rule bulk --add_storages
```

## 6. CephFS (optional but great for a media server)

RBD gives VMs block disks; **CephFS** is a shared POSIX filesystem all
nodes and VMs can mount simultaneously — ideal for a media library that
containers/VMs on any node need to reach, and for ISOs/templates/backups.

```bash
# MDS on every node (1 active + 2 standby)
pveceph mds create        # run on each node

# filesystem + Proxmox storage entry (node1)
pveceph fs create --name cephfs --add-storage
```

Then in *Datacenter → Storage → cephfs* enable content types you want
(ISO image, backup, snippets…). VMs can mount it via the kernel client:
`mount -t ceph :/ /mnt/media -o name=admin,secretfile=…` or better, a
dedicated cephx client key.

## 7. Final health check

```bash
ceph -s          # HEALTH_OK, 3 mons, 3 osds up/in (or more)
ceph df          # capacity sanity check
ceph osd tree    # one branch per host
```

Or `scripts/99-health-check.sh` for the whole cluster in one shot.

## Capacity discipline

- `ceph df` `MAX AVAIL` already accounts for replication.
- Alarms fire at 85% (near-full) and writes stop at 95% (full). On a
  3-node cluster **treat ~70% as full**: if a disk dies, its data must
  re-replicate into the remaining space — leave room for that.
