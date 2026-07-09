# 10 — Cloud Stack: Nextcloud + Firefly III

A second VM ("cloud", VMID 202, 10.0.0.22) holds the personal-data
apps, kept deliberately separate from the media VM:

| Service | Port | URL | Job |
|---------|------|-----|-----|
| Nextcloud | 8080 | `http://cloud.home.lan` | files, sync, calendar, contacts, photos |
| Firefly III | 8082 | `http://money.home.lan` | personal finance |
| Firefly Importer | 8081 | `http://money-import.home.lan` | CSV/bank-statement import |
| Postgres + Redis | — | — | shared backing services |

## Storage & encryption design

- **Root disk 32 GB** — OS, Docker, app configs, Postgres.
- **Data disk 500 GB (thin)** — Nextcloud user files at
  `/mnt/clouddata`. Unlike the servarr media disk this one **is
  included in vzdump backups**: personal files are not re-acquirable.
- **Encryption at rest is already handled below this VM**: every Ceph
  OSD is LUKS-encrypted (docs/05 §4), so all of this — Nextcloud data,
  databases, everything — is encrypted on the physical disks and
  transparently decryptable while the cluster runs. No Nextcloud
  server-side encryption app needed (it breaks external storage and
  previews; skip it).
- Remote access is via WireGuard (docs/09), so files in transit from
  outside are encrypted end-to-end without exposing Nextcloud to the
  internet.

## 1. Create the VM and bootstrap

```bash
# on any cluster node:
bash scripts/13-create-cloud-vm.sh --ha

# then from a node:
scp -r cloud cloud@10.0.0.22:~
ssh cloud@10.0.0.22
cd cloud && sudo bash bootstrap.sh
```

Bootstrap installs Docker, formats/mounts the data disk, and generates
`.env` with random secrets — **it prints the Nextcloud admin password
once**; save it. Re-login (docker group), then:

```bash
docker compose up -d      # first run builds the Nextcloud+SMB image
```

First start takes a few minutes (image build + Nextcloud installs
itself against Postgres, with Redis file locking preconfigured).

## 2. Wire the media library into Nextcloud (the shared folder)

Prerequisite once, in the **servarr** VM: `sudo bash setup-samba.sh`
(from the `servarr/` directory) — exports `/mnt/data/media` as an SMB
share for user `media`, and doubles as a normal NAS share for laptops
and TVs.

Then in Nextcloud (as admin):

1. Profile menu → *Apps* → enable **External storage support**.
2. *Administration settings → External storage* → add:
   - Folder name: `Media`
   - Storage: **SMB/CIFS** — the custom image ships with the SMB client
   - Host: `10.0.0.20` · Share: `media` · Remote subfolder: *(empty)*
   - Authentication: username/password → `media` + the SMB password you
     set in `setup-samba.sh`
   - Available for: whichever users should see it
3. A green check appears; a `Media` folder shows up in Files with full
   **read/write** — rename, move, delete, upload straight into the same
   files Jellyfin and the *arrs use. (New files land owned by the
   `media` user thanks to `force user`, so hardlinks and imports keep
   working.)

Caveat worth knowing: writes from *outside* Nextcloud (Sonarr imports a
new episode) appear in Nextcloud when the folder is next browsed — SMB
external storage checks the share on access, so no manual rescans
needed in practice.

## 3. Firefly III first run

1. `http://money.home.lan` → register — the **first account created
   becomes the owner**; do it before sharing the URL.
2. Set up your accounts (asset/expense/revenue), then budgets and rules.
3. Importer: `http://money-import.home.lan` → it asks for a Personal
   Access Token — create one in Firefly under *Options → Profile → OAuth
   → Personal Access Tokens*. Use it to import bank CSVs (or wire up a
   bank API where available).

## "Deploy Nextcloud across multiple nodes"

Two tiers — you have the first out of the box:

**Tier 1 (active now): HA failover.** The VM's disks are on Ceph and
it's HA-enrolled, so *any* node can run it and a node failure restarts
it on a survivor in ~2–3 minutes. For a household, this **is** the
right amount of "across multiple nodes" — one Nextcloud instance is
plenty for dozens of users.

**Tier 2 (documented, not built): horizontal scale-out** — multiple
simultaneous Nextcloud app servers behind Caddy load balancing. The
pieces this layout already gets right for that future: Postgres and
Redis are separate services (move them to their own VM), config/data
are cleanly separated, and the media share is already external via SMB.
What you'd add: put `/mnt/clouddata/nextcloud` on shared storage
(CephFS via an NFS/SMB gateway, or a dedicated export from one storage
VM), clone the app VM, point both at the same DB/Redis/data, and change
Caddy's `reverse_proxy` to list both backends. Genuinely only worth it
past ~50 active users or for zero-downtime upgrades — revisit then.

## Day-2

- **Update**: `docker compose pull && docker compose build --pull
  nextcloud && docker compose up -d` (the build step picks up new
  Nextcloud base images).
- **Backups**: VM 202 is in the weekly vzdump job including the data
  disk. Firefly's DB lives in Postgres under `CONFIG_ROOT` on the root
  disk — also covered. Test a restore once before you trust it with
  your finances.
- **Nextcloud clients**: mobile/desktop apps accept the plain-HTTP LAN
  URL with a warning; if that grates, the Caddyfile's `tls internal`
  pattern (see the Vaultwarden block) + installing Caddy's root CA on
  your devices gives green-lock HTTPS — or a real domain later makes it
  automatic.
- **Disk growth**: `qm disk resize 202 scsi1 +200G` on a node, then
  `sudo xfs_growfs /mnt/clouddata` in the VM.
