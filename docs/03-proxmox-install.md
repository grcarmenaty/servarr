# 03 — Installing Proxmox VE

Do this on each of the three nodes. Current target: **Proxmox VE 9.x**
(Debian 13 based); everything here also works on 8.x.

## Prepare the installer

1. Download the latest Proxmox VE ISO from
   <https://www.proxmox.com/en/downloads>.
2. Write it to a USB stick:
   ```bash
   dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
   (or use Ventoy/Rufus in "DD mode").

## BIOS checklist (per node, before installing)

- Enable **VT-x / AMD-V** (often "SVM" on AMD boards).
- Enable **VT-d / IOMMU** if present (needed later for PCI passthrough).
- Disable **Secure Boot** if the installer won't boot.
- Set **power on after AC loss**.
- Boot mode: UEFI preferred, legacy fine on very old boards.

## Installer walkthrough

1. Boot the USB → *Install Proxmox VE (Graphical)*.
2. **Target disk**: pick the small **OS SSD** — double-check you're not
   nuking your intended OSD disk. Filesystem: `ext4` on LVM (default) is
   the right choice for a single OS disk. ZFS RAID is unnecessary here
   and eats RAM you need for Ceph.
3. **Country/timezone/keyboard**: as appropriate. Correct timezone
   matters — Ceph hates clock skew.
4. **Password + email**: same root password on all nodes keeps life
   simple (you can harden later); email can be anything.
5. **Network**:
   - Interface: your **LAN** NIC (not the future Ceph NIC).
   - Hostname (FQDN): `node1.home.lan` (then `node2.…`, `node3.…`).
     The part before the first dot becomes the node name — final answer,
     no renames later.
   - IP/gateway/DNS: the static management address from your plan
     (`docs/02-network.md`).
6. Install, reboot, remove the USB stick.

Repeat for node2 and node3 with their respective hostnames/IPs.

## First login

Web UI: `https://192.168.1.11:8006` (accept the self-signed cert),
user `root`, realm *Linux PAM*. Or SSH: `ssh root@192.168.1.11`.

The "No valid subscription" popup is normal — this cluster runs the free
no-subscription repositories, configured next.

## Post-install (per node)

Copy this repo's `scripts/` directory to the node and run:

```bash
scp -r scripts root@192.168.1.11:/root/
ssh root@192.168.1.11
cd /root/scripts
# edit cluster.env first if you haven't
bash 01-post-install.sh
```

The script does, idempotently:

1. Switches from the enterprise apt repos (which 401 without a
   subscription) to the **no-subscription** repos.
2. Full `apt update && apt dist-upgrade`.
3. Populates `/etc/hosts` with all three nodes from `cluster.env`.
4. Verifies chrony (time sync) is active.
5. Optionally disables the subscription popup nag.

Then configure the second (Ceph) NIC per `docs/02-network.md` and run the
verification pings. When all three nodes are installed, updated, and can
ping each other on every subnet, continue to `docs/04-cluster.md`.
