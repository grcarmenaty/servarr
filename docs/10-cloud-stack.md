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
| Paperless-ngx | cloud-data :8000 | `http://paperless.home.lan` |
| SearXNG | cloud-data :8083 | `http://search.home.lan` |
| Taiga | cloud-data :9000 | `http://taiga.home.lan` |

(The "Redis" service is actually **Valkey** — BSD-licensed, protocol
identical; Redis itself stopped being open source at 7.4. See docs/12.)

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

## Paperless-ngx (documents)

Lives on cloud-data (`http://paperless.home.lan`, login `admin` + the
password bootstrap generated into `.env`). Scan/photograph any
document → drop it in — Paperless OCRs it (language via
`PAPERLESS_OCR_LANGUAGE` in `.env`), tags it, and makes it full-text
searchable. Three ways in:

- web UI upload, or the mobile app
  ([paperless-mobile](https://github.com/paperless-ngx/paperless-mobile))
- the **consume folder**: anything written to
  `/mnt/clouddata/paperless/consume` is ingested automatically — point
  a network scanner at it, or expose it through Nextcloud
- email ingestion (*Settings → Mail*) if you give it a mailbox

Storage is on the backed-up cloud-data disk; the `export/` dir +
`document_exporter` gives a portable dump for extra safety.

## SearXNG (private web search)

`http://search.home.lan` — a metasearch engine that queries
Google/Bing/DDG/Wikipedia/etc. on your behalf and returns merged
results with **no tracking, no profiling, no ads**. Zero accounts by
design (your searches stay anonymous even at home).

- **Set it as the browser default**: most browsers → add custom search
  engine → `http://search.home.lan/search?q=%s`. Works on phones over
  WireGuard too.
- **Tune engines**: first visit → *Preferences* (per-browser via
  cookie), or globally in `/opt/cloud/config/searxng/settings.yml`
  (created on first run) + `docker compose restart searxng`.
- **Enable the JSON API** (needed for the AI assistant's web search,
  docs/16): in `settings.yml` add `json` under `search: formats:`,
  restart.

## Household apps (batteries included)

cloud-data's compose also runs a set of small self-hosted apps — each
authenticated, each behind its own hostname, all sharing the VM's RAM:

| App | URL | What | First-run note |
|-----|-----|------|----------------|
| Karakeep | `bookmarks.home.lan` | bookmarks / read-it-later, AI tagging | sign up (first user); then `DISABLE_SIGNUPS=true`. Optional: point its AI at the assistant (below) |
| Mealie | `recipes.home.lan` | recipes + meal planning | create the first user (signup then closes) |
| Grocy | `grocy.home.lan` | groceries, chores, stock, expiry | default login `admin`/`admin` → change it |
| Homebox | `inventory.home.lan` | home inventory (boxes, warranties) | register; then set `HBOX_OPTIONS_ALLOW_REGISTRATION=false` |
| FreshRSS | `rss.home.lan` | RSS/news reader | guided install wizard on first visit |
| ArchiveBox | `archive.home.lan` | permanent local copies of web pages | `docker exec archivebox archivebox manage createsuperuser` |
| BookStack | `wiki.home.lan` | household wiki/documentation | default `admin@admin.com`/`password` → change immediately |
| Element + Conduit | `element.home.lan` | Matrix family chat (federation off) | register in Element with `MATRIX_REGISTRATION_TOKEN` from `.env`; server `matrix.home.lan` |

**Karakeep + your own AI**: uncomment the `OPENAI_*` lines in the
compose, set the base URL to `http://10.0.0.27:3000/api` and an Open
WebUI API key (docs/16) — bookmarks get summarized and auto-tagged by
your local model, nothing sent to any vendor.

All secrets are generated by `bootstrap.sh`; none ship as real
defaults. These are convenience apps — none is HA-critical, but they
ride cloud-data's HA for free.

## Taiga (project management)

Kanban/scrum boards, epics, sprints, wiki — for the household projects
that outgrow a notes app (this build itself would fit). Deployed from
Taiga's **official `taiga-docker`** stack (it brings its own Postgres +
RabbitMQ; upstream stays authoritative):

```bash
# on cloud-data, after the main stack is up:
sudo bash setup-taiga.sh
# then, once taiga-back is healthy (~1 min):
cd /opt/taiga-docker && ./taiga-manage.sh createsuperuser
```

Log in at `http://taiga.home.lan`. Notes:

- Public registration is off; add users via `/admin/` (Django admin).
- No SMTP at home → invite/notification emails print to
  `docker logs taiga-back` instead of sending. Wire real SMTP later in
  `/opt/taiga-docker/.env` if you ever want email.
- Upgrades: `cd /opt/taiga-docker && git pull && docker compose pull &&
  docker compose up -d`.

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
