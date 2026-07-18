# BUILD RUNBOOK — Zero to Full Platform

The complete build, in order, with exact values and a checkpoint after
every phase. **Don't proceed past a failed checkpoint.** Deep
explanations live in `docs/` — this file is the "do this now" track.

Conventions used everywhere below:

| Thing | Value |
|-------|-------|
| Nodes | `node1` 10.0.0.11 · `node2` 10.0.0.12 · `node3` 10.0.0.13 |
| LAN / gateway / DNS | 10.0.0.0/24 · 10.0.0.254 · 10.0.0.254 (router, during build) |
| Ceph mesh | 10.10.10.11 / .12 / .13 (no gateway, no switch) |
| Domain | `home.lan` |
| Root password | same on all 3 nodes (write it down now) |

**Where commands run** — every command block below is one of:

| Marker | Meaning |
|--------|---------|
| *(any node)* | cluster-wide effect; run on whichever node you're logged into |
| *(each node)* | must be repeated on node1, node2, AND node3 |
| *(nodeN only)* | that specific node |
| ⚠ *(GPU node only)* | **only** the node physically holding the GPU — set `GPU_NODE=` in `cluster.env`; the GPU scripts refuse to run elsewhere |
| *(inside VM x.x.x.x)* | SSH into that guest, not a node |

Rough wall-clock: Phases 0–8 (cluster ready) ≈ one afternoon.
Phases 9–12 (all services) ≈ a weekend, mostly waiting on downloads.

---

## Phase 0 — Before touching hardware (~30 min)

1. **Download** the latest Proxmox VE ISO:
   <https://www.proxmox.com/en/downloads> → *Proxmox VE ISO Installer*.
2. **Write it to USB** (double-check `/dev/sdX` is the USB stick!):
   ```bash
   dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
   (Windows/macOS: Rufus in **DD mode**, or balenaEtcher.)
3. **Router prep** (admin UI of 10.0.0.254):
   - Ensure the DHCP pool does **not** include 10.0.0.5–10.0.0.30
     (our static range). Shrink the pool or reserve the range.
   - Note where the DHCP DNS setting lives — you'll change it in Phase 9.
4. **Cables**: 3× LAN patch cables + 3× 10G cables (DAC/SFP+ or Cat6a
   depending on your NICs) for the mesh triangle.
5. **Per node, identify and physically label**:
   - the OS disk (one of the four 1 TB — if any 1 TB is an SSD, that one)
   - the 1 GbE port ("LAN") and the two 10 GbE ports ("X" and "Y")
6. Edit `scripts/cluster.env` if any value in the table above isn't
   what you want. **Everything downstream reads this file.**

**Checkpoint 0**: USB written, DHCP pool excludes .5–.30, six port
labels + three disk labels applied, `cluster.env` reviewed.

---

## Phase 1 — BIOS, each node (~5 min/node)

Boot each machine into BIOS/UEFI setup (usually `Del` or `F2`):

| Setting | Value |
|---------|-------|
| SVM / AMD-V (CPU virtualization) | **Enabled** |
| IOMMU (AMD-Vi) | Enabled (if present) |
| Secure Boot | **Disabled** |
| Restore AC Power Loss | **Power On** |
| Boot order | USB first (or use the one-time boot menu, usually `F8`/`F11`/`F12`) |
| SATA mode | AHCI (not RAID) |

**Checkpoint 1**: all three machines boot the Proxmox USB to the
installer menu.

---

## Phase 2 — Install Proxmox VE, node by node (~15 min/node)

> Full parameter reference incl. advanced LVM options and unattended
> installs: `docs/03-proxmox-install.md`.

**Tip:** during each install, have **only the 1 GbE LAN cable**
plugged — the installer preselects the NIC with link, which removes
all guesswork about which port is which.

Boot the USB → **Install Proxmox VE (Graphical)**. Screens, in order:

### Screen 1 — EULA
`I agree`.

### Screen 2 — Target Harddisk
- **Target**: the labeled 1 TB **OS disk**. Verify by size/model —
  the dropdown shows both. **This disk is erased.**
- **Options** button:

| Parameter | Value | Why |
|-----------|-------|-----|
| Filesystem | `ext4` | single OS disk; ZFS costs RAM Ceph needs |
| hdsize | *(default = whole disk)* | fine — the OS uses little; local-lvm slack is harmless |
| swapsize | `8` | explicit 8 GiB; predictable |
| maxroot | *(default)* | |
| minfree | *(default)* | |
| maxvz | *(default)* | creates `local-lvm`; barely used since guests live on Ceph |

### Screen 3 — Localization
| Parameter | Value |
|-----------|-------|
| Country | yours (e.g. `Spain`) |
| Time zone | yours (e.g. `Europe/Madrid`) — must be correct, Ceph hates clock skew |
| Keyboard | yours (e.g. `es`) |

### Screen 4 — Administration
| Parameter | Value |
|-----------|-------|
| Password | the shared root password from your notes |
| Email | `root@home.lan` (or a real one for alerts later) |

### Screen 5 — Management Network ← the one that differs per node
| Parameter | node1 | node2 | node3 |
|-----------|-------|-------|-------|
| Management interface | *the 1 GbE NIC (the one with link)* | 〃 | 〃 |
| Hostname (FQDN) | `node1.home.lan` | `node2.home.lan` | `node3.home.lan` |
| IP Address (CIDR) | `10.0.0.11/24` | `10.0.0.12/24` | `10.0.0.13/24` |
| Gateway | `10.0.0.254` | `10.0.0.254` | `10.0.0.254` |
| DNS Server | `10.0.0.254` | `10.0.0.254` | `10.0.0.254` |

(DNS is the **router** for now — AdGuard doesn't exist yet.)

### Screen 6 — Summary
Read every line against the tables above → tick *Automatically reboot
after successful installation* → **Install**. Remove the USB when it
reboots.

**Checkpoint 2** (after all three): from your PC,
`https://10.0.0.11:8006`, `...12:8006`, `...13:8006` each show a login
page (accept the self-signed cert); `root` + password logs in, realm
*Linux PAM*. The "No valid subscription" popup is expected — Phase 3
configures the free repos.

---

## Phase 3 — Post-install, each node (~10 min/node)

From your PC, copy the scripts to **each** node and run the
post-install (repos → no-subscription, updates, `/etc/hosts`, chrony):

```bash
scp -r scripts root@10.0.0.11:/root/       # then .12, .13
ssh root@10.0.0.11
cd /root/scripts && bash 01-post-install.sh
```

**Checkpoint 3**, on each node:
```bash
apt update                     # no 401/subscription errors
getent hosts node1 node2 node3 # all three resolve
chronyc tracking               # "Leap status: Normal", small offset
```

---

## Phase 4 — 10 GbE mesh (~20 min)

1. **Cable the triangle** (labels from Phase 0):
   `node1:X→node2:Y`, `node2:X→node3:Y`, `node3:X→node1:Y`.
2. On **each** node, find the two 10G port names:
   ```bash
   ip -br link                       # candidates
   ethtool <name> | grep Speed       # 10000Mb/s = a mesh port
   ```
   Which is X and which is Y: `ethtool <name> | grep Link` while
   unplugging one cable — the port whose link drops is the one that
   cable serves.
3. On **each** node:
   ```bash
   bash /root/scripts/00-ceph-mesh-network.sh <portX> <portY>
   ```

**Checkpoint 4**, on **each** node (all must pass):
```bash
ping -c2 10.10.10.11 && ping -c2 10.10.10.12 && ping -c2 10.10.10.13
ping -c2 -M do -s 8972 10.10.10.12        # jumbo frames pass
ping -c2 -M do -s 8972 10.10.10.13
```

---

## Phase 5 — Form the cluster (~10 min)

```bash
# node1:
bash /root/scripts/02-create-cluster.sh create
# node2, AFTER node1 finishes (asks for node1's root password):
bash /root/scripts/02-create-cluster.sh join
# node3, AFTER node2 finishes:
bash /root/scripts/02-create-cluster.sh join
```

**Checkpoint 5**: `pvecm status` on any node shows `Nodes: 3`,
`Quorate: Yes`; any node's web UI shows all three under *Datacenter*.

---

## Phase 6 — Ceph (~45 min)

```bash
# 1. install packages — on EVERY node:
bash /root/scripts/03-setup-ceph.sh install
# 2. initialize — node1 ONLY:
bash /root/scripts/03-setup-ceph.sh init
# 3. monitor+manager — on EVERY node, one at a time:
bash /root/scripts/03-setup-ceph.sh mon
```

Mid-checkpoint: `ceph -s` → `mon: 3 daemons`, `mgr: ...standbys: 2`.

**OSDs** — on **each** node, for **each of its 5 data disks**
(2× 3 TB + 3× 1 TB; the OS disk is excluded automatically):

```bash
lsblk -o NAME,SIZE,ROTA,MODEL,SERIAL   # identify; ROTA 1=HDD 0=SSD
bash /root/scripts/04-create-osds.sh /dev/sdb   # confirm prompt per disk
# ... repeat /dev/sdc /dev/sdd /dev/sde /dev/sdf (your names will vary)
```

Every OSD is **LUKS-encrypted** (`OSD_ENCRYPT=yes`). After the last one:

```bash
# KEY ESCROW — once, save output somewhere OFF-cluster (password manager):
ceph config-key dump | grep dm-crypt
```

**Checkpoint 6**: `ceph osd tree` shows **15 OSDs**, all `up`/`in`,
5 under each host; `ceph -s` → `HEALTH_OK`.

---

## Phase 7 — Pools + CephFS (~5 min, once, any node)

```bash
bash /root/scripts/05-create-pools.sh
```

**Checkpoint 7**: `ceph -s` → `HEALTH_OK`; *Datacenter → Storage* shows
`vm-pool` (RBD) and `cephfs`; `ceph df` shows ~27 TB raw.

---

## Phase 8 — Cluster acceptance test (~30 min, do not skip)

```bash
bash /root/scripts/99-health-check.sh      # all green
```

Then the **reboot drill** — now, while there's no data to lose:

1. Reboot node3. Watch `ceph -s` on node1: `HEALTH_WARN`, degraded PGs.
2. Cluster keeps answering (`pvecm status` quorate on node1/2).
3. node3 returns → within minutes `HEALTH_OK` again.

**Checkpoint 8**: the drill behaved exactly as described. You now have
a working hyperconverged cluster. Everything after this is services.

---

## Phase 9 — Guests (the long phase; each block is independent)

Run VM/LXC creation scripts on any node. After each `scp`+`bootstrap`,
the service doc's **first-run checklist** is part of the step.

**9a. Media VM** — `docs/08`:
```bash
bash /root/scripts/10-create-servarr-vm.sh --ha
scp -r servarr media@10.0.0.20:~ && ssh media@10.0.0.20
cd servarr && sudo bash bootstrap.sh && exit && ssh media@10.0.0.20
cd servarr && docker compose up -d              # (+ vpn overlay if used)
sudo bash setup-samba.sh                        # media SMB share
```
→ then docs/08 first-run order (qBittorrent → Prowlarr → Sonarr →
Radarr → Bazarr → Jellyfin → Jellyseerr → Audiobookshelf → Kavita).

**9b. Core LXCs** — `docs/09` (now 7: adguard, caddy, wireguard, kuma,
adguard2, ntfy, forgejo):
```bash
bash /root/scripts/11-create-core-lxcs.sh all --ha
```
→ AdGuard wizards on `:3000` at 10.0.0.5 **and** 10.0.0.9 (DNS
rewrites table in docs/09) → **router DHCP DNS = 10.0.0.5 + 10.0.0.9**
→ WireGuard: DDNS + forward UDP 51820 → 10.0.0.7, `wg-add-peer phone`
→ Kuma admin + monitors → ntfy topic in Kuma + phone app → Forgejo
admin account (`git.home.lan`, provisioner prints the command).

**9c. Home Assistant** (optional): `bash /root/scripts/12-create-haos-vm.sh --ha`
→ reserve 10.0.0.21 for the printed MAC in the router.

**9d. Cloud tier** — `docs/10`, order matters:
```bash
bash /root/scripts/13-create-cloud-vms.sh --ha
# 1) cloud-data (prints DB/Redis passwords):
scp -r cloud/data cloud@10.0.0.22:~/cloud-data && ssh cloud@10.0.0.22
cd cloud-data && sudo bash bootstrap.sh && exit && ssh cloud@10.0.0.22
cd cloud-data && docker compose up -d && sudo bash init-guacamole.sh
# 2) cloud1 — paste passwords into .env, then up, WAIT for install:
scp -r cloud/app cloud@10.0.0.23:~/cloud-app && ssh cloud@10.0.0.23
cd cloud-app && sudo bash bootstrap.sh && nano .env
docker compose up -d --build     # wait for http://10.0.0.23:8080 login page
# 3) cloud2 — identical to cloud1 (10.0.0.24)
```
→ Nextcloud: External storage → SMB `Media` (docs/10) → Firefly owner
account → bank connections (docs/10 §banks) → Paperless admin login.
Optional, same VM: `sudo bash setup-taiga.sh` + `taiga-manage.sh
createsuperuser` → project boards at `http://taiga.home.lan`.
The household apps (Karakeep, Mealie, Grocy, Homebox, FreshRSS,
ArchiveBox, BookStack, Element/Matrix) come up with cloud-data's
`docker compose up -d` — first-run notes per app in docs/10.

**9e. Photos** — `docs/11`:
```bash
bash /root/scripts/14-create-photos-vm.sh --ha
scp -r photos cloud@10.0.0.25:~ && ssh cloud@10.0.0.25
cd photos && sudo bash bootstrap.sh && exit && ssh cloud@10.0.0.25
cd photos && docker compose up -d
```
→ admin account at `:2283`, mobile apps → auto-backup.

**9f. Wazuh SIEM** — `docs/14`:
```bash
bash /root/scripts/15-create-wazuh-vm.sh --ha
scp -r wazuh cloud@10.0.0.26:~ && ssh cloud@10.0.0.26
cd wazuh && sudo WAZUH_VERSION=4.14.6 bash bootstrap.sh
```
→ change default dashboard credentials → enroll agents everywhere:
`bash 25-install-wazuh-agent.sh` on each node, `scp`+run in each VM,
`pct push`+exec in each LXC.

**9g. AI assistant + local voice** — `docs/16`. **CPU by default**, any
node. Choose **one** packaging (same IP/hostname):

*Docker VM* (default):
```bash
bash /root/scripts/16-create-ai-vm.sh              # any node
scp -r ai cloud@10.0.0.27:~ && ssh cloud@10.0.0.27
cd ai && sudo bash bootstrap.sh                    # single pass (CPU)
docker compose up -d && docker exec ollama ollama pull qwen3:8b
```
*or native LXC* (lighter; better GPU sharing — docs/16):
```bash
bash /root/scripts/17-create-ai-lxc.sh             # --gpu 01:00 on GPU_NODE
pct exec 108 -- ollama pull qwen3:8b
```
→ **first signup = admin** at `http://chat.home.lan`, then disable
signups. Add the Whisper/Piper Wyoming services to Home Assistant for
local voice (docs/16). Optional GTX 960 acceleration pins the guest and
drops its HA — see docs/16.

**Checkpoint 9**: `http://home.lan` portal loads from a LAN device and
**every tile works**; phone on mobile data connects via WireGuard and
reaches the portal too.

---

## Phase 10 — HA everything + failover drill (~30 min)

```bash
bash /root/scripts/20-enable-ha.sh
```

Verify placement: *Datacenter → HA* — all services `started`, and
cloud1/cloud2 on **different** nodes, adguard/adguard2 on **different**
nodes (the anti-affinity rules).

**The drill** (evening, family warned): pick the node running cloud1,
pull its power cord.

| T+ | Expected |
|----|----------|
| 0–1 min | Nextcloud still works (cloud2 serves); DNS still works; Jellyfin dead if it lived there |
| ~1–2 min | node fenced; HA manager starts recovery |
| ~3–5 min | every service back; `ceph -s` HEALTH_WARN (degraded, expected) |
| power back | node rejoins; Ceph heals to HEALTH_OK; drift VMs migrate back per rules |

**Checkpoint 10**: timeline matched; nothing needed manual intervention.

---

## Phase 11 — Hardening + monitoring (~30 min)

```bash
# each node:
bash /root/scripts/21-harden-nodes.sh
bash /root/scripts/23-install-ntopng.sh
# once, from one node (read the lockout note in the script header first):
bash /root/scripts/22-enable-firewall.sh
```

**Checkpoint 11**: web UI + SSH still reachable **after** the firewall
enables; `fail2ban-client status` lists 2 jails on each node;
`http://traffic.home.lan` shows flows.

---

## Phase 12 — Backups + final acceptance (~30 min + overnight)

1. *Datacenter → Backup → Add*: all guests, weekly (e.g. Sun 03:00),
   storage `cephfs`, mode Snapshot, keep-last 3. (The media and Wazuh
   data disks are already excluded; personal-data disks are included.)
2. After the first run: pick a small LXC, restore it to a new ID,
   confirm it boots. **A backup you haven't restored is a hope, not a
   backup.**
3. Escrow checklist — all stored off-cluster (password manager):
   root password · dm-crypt key dump (Phase 6) · WireGuard server key
   (`/etc/wireguard/` in LXC 103) · every generated `.env`
   (cloud-data, cloud/app ×2, servarr, photos, wazuh, ai, and
   `/opt/taiga-docker/.env`) · admin passwords printed by the bootstraps
   (Nextcloud, Guacamole, Wazuh, Paperless, BookStack, and the
   Forgejo/Immich/Firefly/Taiga/Karakeep/Homebox first-user accounts).
   A `.gitignore` keeps `.env` files out of git, but the copies inside
   the VMs are the ones that matter — back them up.

### Final acceptance checklist

| # | Test | Pass |
|---|------|------|
| 1 | `99-health-check.sh` all green on all 3 nodes | ☐ |
| 2 | `ceph -s` HEALTH_OK, 15 OSDs up/in | ☐ |
| 3 | Portal + every tile from LAN | ☐ |
| 4 | Same, from phone on mobile data via WireGuard | ☐ |
| 5 | Ad blocking works (test device: `dns.home.lan` query log shows it) | ☐ |
| 6 | Jellyfin plays; Sonarr grabs → hardlink-imports; SMB share mounts from a laptop | ☐ |
| 7 | Nextcloud: login stays alive while `docker compose stop` runs on cloud1 | ☐ |
| 8 | Immich mobile auto-backup uploads a photo | ☐ |
| 9 | Kuma alert reaches phone via ntfy (stop a container to trigger) | ☐ |
| 10 | Wazuh dashboard: all agents green | ☐ |
| 11 | Power-pull drill passed (Phase 10) | ☐ |
| 12 | Backup restore test passed | ☐ |
| 13 | Router: UPnP off; only forward is UDP 51820 | ☐ |
| 14 | Escrow list complete, stored off-cluster | ☐ |

All ticked → the build is done. Ongoing care: `docs/09` (updates
policy, UPS), `docs/13` (quarterly checklist).
