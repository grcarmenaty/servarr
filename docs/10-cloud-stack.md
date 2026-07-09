# 10 — Cloud Tier: Nextcloud (×2, load-balanced) + Firefly III

Nextcloud runs as **two simultaneous app servers on different nodes**,
load-balanced by Caddy — kill either VM (or its node) and file syncs,
web sessions, and mobile clients continue on the survivor without a
blip. All state lives one layer down, on a shared-services VM.

```
                      http://cloud.home.lan
                            │  (Caddy: least-connections,
                            │   health-checked)
              ┌─────────────┴─────────────┐
              ▼                           ▼
     ┌────────────────┐          ┌────────────────┐
     │  cloud1 (203)  │          │  cloud2 (204)  │   stateless app VMs,
     │  10.0.0.23     │          │  10.0.0.24     │   anti-affinity keeps
     │  nextcloud+cron│          │  nextcloud     │   them on ≠ nodes
     └───────┬────────┘          └───────┬────────┘
             │      NFS (html+data),     │
             │      Postgres, Redis      │
             └───────────┬───────────────┘
                         ▼
                ┌─────────────────┐
                │ cloud-data (202)│  Postgres 17 · Redis · NFS export
                │ 10.0.0.22       │  Firefly III + importer
                └─────────────────┘  500 GB data disk (backed up)
```

| Service | Where | URL |
|---------|-------|-----|
| Nextcloud (×2) | cloud1/cloud2 :8080 | `http://cloud.home.lan` |
| Firefly III | cloud-data :8082 | `http://money.home.lan` |
| Firefly Importer | cloud-data :8081 | `http://money-import.home.lan` |

## Why this works with two instances

- **Sessions & locks in Redis** — the Nextcloud image switches PHP
  sessions to Redis automatically when `REDIS_HOST` is set, so either
  backend can serve any request; no sticky sessions.
- **Code + config + data on NFS** from cloud-data — both instances run
  literally the same `config.php` and see the same files instantly.
- **One database** in Postgres on cloud-data.
- **Caddy health-checks** `/status.php` every 10 s and stops routing to
  a dead backend within seconds (`fail_duration 15s`).
- The cron/background-jobs container runs on **cloud1 only** (compose
  profile) — jobs must not run twice.

Honest asterisk: cloud-data itself is a singleton. It's HA-enrolled, so
a node death means Nextcloud pauses ~2–3 minutes while it restarts
elsewhere — the app tier survives *its* failures with zero downtime,
the data tier self-heals. (True zero-downtime storage would mean
Postgres replication + clustered file backend; out of homelab scope,
sketched at the bottom.)

## Storage & encryption

- cloud-data's **500 GB data disk** holds `/mnt/clouddata/nextcloud`
  (`html/` = code+config, `data/` = user files), exported over NFSv4 to
  the two app IPs only. Personal files are **included in vzdump
  backups** (unlike the re-acquirable media disk).
- Encryption at rest is inherited from the LUKS-encrypted OSDs
  (docs/05 §4) — Nextcloud data, database, everything. Skip Nextcloud's
  server-side encryption app (breaks external storage + previews).
- Remote access via WireGuard = encrypted in transit (docs/09).

## Deploy

```bash
# on any cluster node — creates all three VMs:
bash scripts/13-create-cloud-vms.sh --ha
```

Then bootstrap **in order**:

**1. cloud-data** (10.0.0.22):

```bash
scp -r cloud/data cloud@10.0.0.22:~/cloud-data
ssh cloud@10.0.0.22
cd cloud-data && sudo bash bootstrap.sh
# re-login, then:
docker compose up -d
```

Bootstrap formats the data disk, sets up the NFS export, generates
secrets, and **prints the POSTGRES/REDIS passwords** — you'll paste
those into both app VMs.

**2. cloud1** (10.0.0.23):

```bash
scp -r cloud/app cloud@10.0.0.23:~/cloud-app
ssh cloud@10.0.0.23
cd cloud-app && sudo bash bootstrap.sh     # mounts NFS, creates .env
nano .env                                  # paste the two passwords
docker compose up -d --build
```

Wait until `http://10.0.0.23:8080` shows the login page — the first
instance installs Nextcloud into the shared directory (a few minutes).
The admin password was printed by bootstrap (also in `.env`).

**3. cloud2** (10.0.0.24): same four commands as cloud1. It finds the
finished install on NFS and just starts serving.

**4. HA + anti-affinity** (any node):

```bash
bash scripts/20-enable-ha.sh
```

Verify the load balancing: `http://cloud.home.lan`, then
`docker compose stop` on either app VM — refresh, you're still logged
in and working.

## Wire the media library in (the shared folder)

Once, in the **servarr** VM: `sudo bash setup-samba.sh`. Then as the
Nextcloud admin: *Apps* → enable **External storage support** →
*Administration → External storage*:

- Folder name `Media`, type **SMB/CIFS** (the custom image ships the
  SMB client), host `10.0.0.20`, share `media`, username `media` + the
  SMB password.

Full read/write on the same files Jellyfin and the *arrs use, from
both app instances identically. New files land owned by the `media`
user (`force user`), so *arr hardlinks keep working.

## Firefly III first run

`http://money.home.lan` → register (**first account = owner**), create
your asset accounts, then wire up your banks below.

## Connecting your banks

The Data Importer (`http://money-import.home.lan`) is pre-wired for
three providers — between them, essentially every bank you can hold:

| Provider | Coverage | Status |
|----------|----------|--------|
| **Enable Banking** | ~2,500 EEA banks — Revolut, N26, BBVA, Santander, CaixaBank, ING, bunq… | primary; free "restricted mode" for your own accounts |
| GoCardless Bank Account Data | similar EEA coverage | legacy — only if you already hold an account (new signups restricted) |
| CSV / camt.053 files | **any bank on earth** | universal fallback; most banks export CSV |

(Salt Edge/Spectre lost its free tier in late 2025 and is being removed
from the importer — ignore older guides recommending it.)

### Enable Banking setup (once)

1. Register at [enablebanking.com](https://enablebanking.com) → create
   an **application** (redirect URL: `http://money-import.home.lan/`) —
   you get an *Application ID* and a private **PEM key**.
2. On cloud-data, drop the key at
   `/opt/cloud/config/firefly-importer/keys/enablebanking.pem`, then in
   `.env` set `ENABLE_BANKING_APP_ID=...` and uncomment
   `ENABLE_BANKING_PRIVATE_KEY_FILE=/keys/enablebanking.pem`.
3. In Firefly (*Options → Profile → OAuth*) create a **Personal Access
   Token** → paste into `.env` as `FIREFLY_ACCESS_TOKEN`.
4. `docker compose up -d` to reload the importer.

Per bank: importer UI → *Enable Banking* → pick the bank → approve in
the bank's own app/site → map accounts → import. At the end, **save the
import configuration** — download the JSON and drop it into
`/opt/cloud/config/firefly-importer/import/`.

### Automatic daily sync

Bootstrap installed a cron job that hits the importer's `/autoimport`
endpoint at **06:30 daily** — every saved JSON config in the `import/`
dir re-runs unattended, and Firefly's duplicate detection keeps
overlapping pulls harmless. So: connect each bank once through the UI,
save its config, and transactions flow in every morning.

PSD2 realities that apply to *any* provider (not the importer's fault):

- Bank consents expire every **90–180 days** — the bank stops answering
  until you re-approve in the importer UI. Set a recurring reminder (or
  add an Uptime Kuma "push" monitor the cron pings on success — it'll
  alert when imports quietly stop).
- Free tiers rate-limit polling to a few syncs per account per day —
  once daily is exactly the intended cadence.

### Banks that resist (or non-EEA)

Export CSV from the bank's app → importer UI → *File import*. The first
run you map columns by hand; save the config and subsequent statements
are two clicks (or drop the CSV next to its config in `import/` and let
the nightly run eat it). Works for literally any bank, brokerage, or
crypto exchange that can produce a CSV.

## Upgrades — the one multi-instance gotcha

Never run two *different* Nextcloud versions against the shared
directory. Order:

```bash
# cloud2: stop serving
docker compose down
# cloud1: upgrade (runs the migration on the shared html)
docker compose build --pull && docker compose up -d
# → wait until the web UI is back and healthy, then cloud2:
docker compose build --pull && docker compose up -d
```

(While cloud2 is down Caddy routes everything to cloud1 — zero user
downtime for minor updates.)

## If you ever need more

- Third app instance: add a VM, mount NFS, same compose, add its IP to
  the Caddy block and `NEXTCLOUD_TRUSTED_DOMAINS`.
- Removing the cloud-data singleton: Postgres streaming replication +
  Patroni, Redis Sentinel, and CephFS-backed data — real infrastructure,
  only worth it well beyond household scale.
