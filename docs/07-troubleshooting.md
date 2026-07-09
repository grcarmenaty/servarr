# 07 — Troubleshooting (Small-Cluster / Old-Hardware Edition)

The failures you'll actually hit on a 3-node scrap cluster, roughly in
order of likelihood.

## First commands, always

```bash
ceph -s                      # ceph health summary
pvecm status                 # cluster quorum
ceph health detail           # what exactly is unhappy
journalctl -b -u 'ceph-*' -u corosync -u pve-cluster --since -1h
```

## "clock skew detected on mon.X"

The classic scrap-hardware failure — usually a dead CMOS battery, so the
node boots with a wild clock before chrony catches up.

```bash
chronyc tracking             # offset should be milliseconds
chronyc makestep             # force immediate correction
```

Persistent offender → replace its CR2032. Monitors tolerate 50 ms by
default; don't raise the tolerance, fix the clock.

## An OSD is `down` or flapping (down/up/down)

```bash
ceph osd tree                            # which one, which host
journalctl -u ceph-osd@<id> --since -1h  # why
```

Common causes, in order:

1. **Dying disk** — check `smartctl -a /dev/sdX`; pending/reallocated
   sectors → replace it (see below).
2. **OOM kill** — `dmesg | grep -i oom`. Lower `osd_memory_target`
   (docs/05) or add RAM.
3. **Ceph network problem** — flaky cable/switch port on the 10.10.10.x
   net; OSDs get reported down by peers they can't heartbeat.
4. **SMR drive** choking under recovery load — no fix, replace with CMR.

One node down is not an emergency: `HEALTH_WARN` with `degraded` PGs is
Ceph operating as designed. It heals itself when the node returns.

## Replacing a dead disk

```bash
ceph osd out <id>                     # if not already out
systemctl stop ceph-osd@<id>
pveceph osd destroy <id> --cleanup    # removes OSD + wipes LVM leftovers
# swap the physical disk, then:
pveceph osd create /dev/sdX
```

Ceph backfills automatically. Expect hours on HDD/gigabit; the cluster
stays usable meanwhile.

## Recovery is crushing my VMs (everything slow after a failure)

Recovery competes with client I/O. On weak hardware, throttle it:

```bash
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 1
```

(These are the conservative values; raise temporarily if you *want* a
faster rebuild overnight.)

## Cluster lost quorum (`pvecm status`: Quorate: No)

Two nodes are down or corosync links are broken. Symptoms: `/etc/pve`
read-only, can't start/stop VMs, GUI shows question marks.

1. Get a second node back online — that's the real fix.
2. Genuine emergency, one survivor, need to manage VMs *now*:
   ```bash
   pvecm expected 1
   ```
   Temporary (resets on reboot). Never use it while the "dead" nodes
   might actually be alive on a partitioned network.

## `ceph -s` shows PGs `inactive` / I/O frozen

Means fewer than `min_size=2` copies are available — i.e. **two** OSDs
holding the same data are down. Get one of them back and I/O resumes.
This is why you never take two nodes down at once, and never set
`min_size=1` to "fix" it (that trades a freeze for silent data loss).

## Pool/cluster near-full

```bash
ceph df && rados df
```

- Delete old snapshots and unused disk images first (`Datacenter →
  Storage`, orphaned disks show under VM → Hardware).
- RBD images are thin, but deleted data inside a VM isn't returned until
  the guest runs `fstrim` — enable *Discard* on VM disks and
  `fstrim.timer` in guests.
- Real fix: add a disk to each node (`pveceph osd create`). Adding to
  only one node doesn't help — replication needs space on *three* hosts.
- At 95% Ceph stops all writes cluster-wide, VMs pause on I/O. If you get
  there: `ceph osd set-full-ratio 0.97` buys minutes to delete things —
  then fix capacity properly.

## A node won't rejoin after reboot

```bash
systemctl status corosync pve-cluster
journalctl -u corosync -b
```

- Check `/etc/hosts` still lists all nodes and the LAN cable/IP is right.
- Time sync again (`chronyc tracking`).
- `pvecm status` on a healthy node to see whether the cluster sees it.

## Web UI dead on one node, VMs fine

```bash
systemctl restart pveproxy pvedaemon
```

Happens after failed upgrades or full root filesystems (`df -h /` —
old journal logs on a 32 GB OS disk: `journalctl --vacuum-size=500M`).

## When you're stuck

`ceph health detail` output + the relevant `journalctl` lines are what
you paste into a search or an issue. The Proxmox forum threads on any
given error are excellent — include your `pveversion -v` and `ceph
versions` output.
