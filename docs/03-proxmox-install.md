# 03 — Installing Proxmox VE (full parameter reference)

Do this on each of the three nodes. Current target: **Proxmox VE 9.x**
(Debian 13 based); everything here also works on 8.x. The terse
copy-paste track lives in `RUNBOOK.md` Phase 2 — this page explains
every parameter and the non-default paths.

## Prepare the installer

1. Download the latest Proxmox VE ISO from
   <https://www.proxmox.com/en/downloads>.
2. Write it to a USB stick (⚠ `of=` must be the stick, check `lsblk`):
   ```bash
   dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
   Windows/macOS: Rufus (**DD mode** when asked) or balenaEtcher.

## BIOS checklist (per node, before installing)

Enter setup (usually `Del`/`F2` at power-on):

- **SVM / AMD-V** (CPU virtualization): *Enabled* — mandatory, VMs
  won't start without it.
- **IOMMU / AMD-Vi**: *Enabled* if present (future PCI passthrough).
- **Secure Boot**: *Disabled*.
- **Restore on AC Power Loss**: *Power On* — the cluster must come
  back by itself after an outage.
- **SATA mode**: AHCI (never "RAID").
- Boot the USB via the one-time boot menu (`F8`/`F11`/`F12` on most
  boards) rather than permanently reordering.

## Identifying the right disk and NIC (before you're in the installer)

- **OS disk**: one specific 1 TB drive per node (the SSD if one of the
  1 TBs is an SSD — `docs/00`). The installer's disk dropdown shows
  *model + size*; note the model string of your chosen disk beforehand
  (`lsblk -o NAME,SIZE,MODEL,SERIAL` from any live USB, or the sticker).
- **Management NIC**: the 1 GbE port. Easiest trick: **plug in only
  the LAN cable** during installation — the installer preselects the
  interface that has link. The 10 GbE ports stay empty until Phase 4.

## Installer, screen by screen

Boot → *Install Proxmox VE (Graphical)*.

### 1. EULA
*I agree*.

### 2. Target Harddisk

**Target disk**: the designated OS disk — verify model + size in the
dropdown. Everything on it is destroyed.

**Options → Filesystem**: choose **`ext4`**.

Why not the others, since you'll be asked: `zfs (RAIDx)` is for
multi-disk OS arrays and reserves RAM for its cache (ARC) that this
design gives to Ceph; `xfs` is fine but has no advantage here; `btrfs`
is still marked technology preview. Single OS disk + guests on Ceph =
plain ext4 on LVM.

**Options → Advanced (LVM)** — what each knob means, and our values:

| Parameter | Meaning | Our value |
|-----------|---------|-----------|
| `hdsize` | how much of the disk LVM uses at all | default (whole disk) |
| `swapsize` | swap LV size (GiB) | **8** — explicit, predictable |
| `maxroot` | max size of the root (`/`) LV | default (installer picks sanely) |
| `minfree` | space left unallocated in the VG (snapshots/growth) | default |
| `maxvz` | max size of the `data` LV → the `local-lvm` storage | default |

Note on `maxvz`/`local-lvm`: guests live on Ceph, so `local-lvm` will
sit essentially unused. That's fine (it costs nothing until written).
Setting `maxvz: 0` skips creating it entirely — legitimate, but then
delete the `local-lvm` storage entry in the UI to avoid a permanently
"unknown" storage; leaving the default is simpler.

### 3. Localization

| Parameter | Value |
|-----------|-------|
| Country | yours — seeds the apt mirror choice |
| Time zone | **your real zone** (`Europe/Madrid`). Ceph monitors reject peers with clock skew; starting from the right zone matters |
| Keyboard | yours |

### 4. Administration Password + Email

- **Password**: root password, same on all three nodes (cluster join
  asks for it; also your web UI login). Store it in your password
  manager *now*.
- **Email**: target for local alerts (SMART, backups). `root@home.lan`
  works; a real address only becomes useful after you configure an
  SMTP relay (*Datacenter → Notifications*) — optional, later.

### 5. Management Network Configuration

The only screen that differs between nodes:

| Parameter | node1 | node2 | node3 |
|-----------|-------|-------|-------|
| Management interface | the 1 GbE NIC (the one with link) | 〃 | 〃 |
| Hostname (FQDN) | `node1.home.lan` | `node2.home.lan` | `node3.home.lan` |
| IP Address (CIDR) | `10.0.0.11/24` | `10.0.0.12/24` | `10.0.0.13/24` |
| Gateway | `10.0.0.254` | `10.0.0.254` | `10.0.0.254` |
| DNS Server | `10.0.0.254` | `10.0.0.254` | `10.0.0.254` |

- The part before the first dot of the FQDN becomes the **node name**
  — permanent for practical purposes, so get it right here.
- DNS points at the **router** during the build; AdGuard (10.0.0.5/.9)
  doesn't exist yet, and the nodes deliberately keep router DNS even
  after it does (docs/09).

### 6. Summary

Compare every line against the tables above. Tick *Automatically
reboot after successful installation* → **Install** (~5 min). Remove
the USB at reboot.

## First boot & login

- Console shows the URL when ready: `https://10.0.0.1x:8006`.
- Web UI: user `root`, your password, realm **Linux PAM** (not PVE).
- SSH: `ssh root@10.0.0.1x`.
- The "No valid subscription" popup is normal — the free repos are
  configured next by `01-post-install.sh`.

Quick sanity per node before moving on:

```bash
ip -br addr           # vmbr0 has the right IP; 10G ports present, DOWN is fine
cat /etc/hostname     # nodeN
timedatectl           # correct zone
```

## Post-install (per node)

```bash
scp -r scripts root@10.0.0.11:/root/
ssh root@10.0.0.11
cd /root/scripts && bash 01-post-install.sh
```

Idempotent; does: no-subscription repos (deb822 or legacy format,
auto-detected) → full `dist-upgrade` → `/etc/hosts` with all three
nodes → chrony check → optional subscription-nag removal. Then
continue with the mesh (`RUNBOOK.md` Phase 4 / `docs/02`).

## Advanced: unattended installation (optional)

Proxmox supports fully automated installs
([docs](https://pve.proxmox.com/wiki/Automated_Installation)): you bake
an `answer.toml` into the ISO with `proxmox-auto-install-assistant`
and the installer runs hands-off. Worth it if you expect to reinstall
nodes more than once. Per-node answer file matching this build:

```toml
[global]
keyboard = "es"
country = "es"
fqdn = "node1.home.lan"          # ← per node
mailto = "root@home.lan"
timezone = "Europe/Madrid"
root-password = "CHANGE-ME"

[network]
source = "from-answer"
cidr = "10.0.0.11/24"            # ← per node
dns = "10.0.0.254"
gateway = "10.0.0.254"
filter.ID_NET_NAME = "enp3s0"    # ← the 1 GbE NIC name/match

[disk-setup]
filesystem = "ext4"
lvm.swapsize = 8
disk-list = ["sda"]              # ← the OS disk; or use filter.ID_MODEL
```

Prepare with:
```bash
proxmox-auto-install-assistant prepare-iso proxmox-ve.iso \
    --fetch-from iso --answer-file answer-node1.toml
```
(one prepared ISO per node, since hostname/IP differ). Validate first:
`proxmox-auto-install-assistant validate-answer answer-node1.toml`.
For a 3-node one-off, the graphical installer is honestly faster.
