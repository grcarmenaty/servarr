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
| Reverse proxy / DNS (AdGuard, Traefik…) | LXC | vm-pool | yes |
| Home automation | VM/LXC | vm-pool | yes |
| Docker VM for the *arr stack + downloaders | VM | vm-pool (root) + cephfs mount (media) | yes |
| Media server (Jellyfin/Plex) | VM/LXC | vm-pool (root) + cephfs mount (media) | optional |
| Playground / test VMs | VM | vm-pool | no |

The media library lives on CephFS, mounted by whichever guests need it —
so any node can run the media stack, and HA moves it freely.
