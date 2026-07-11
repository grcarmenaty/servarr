# 08 — The Servarr Media Stack

One Debian VM on the cluster runs the whole media stack in Docker
Compose. Its disks live on Ceph, so the VM live-migrates and can be
HA-protected like anything else.

## What runs where

| Service | Port | Job |
|---------|------|-----|
| Jellyfin | 8096 | media server (the thing you watch) |
| Audiobookshelf | 13378 | audiobook + podcast server (apps on every platform) |
| Kavita | 5000 | ebooks, comics & manga reader/server |
| ErsatzTV | 8409 | builds live "TV channels" from your library (`tv.home.lan`) |
| RomM | 8095 | retro-game ROM library manager (`games.home.lan`) |
| Jellyseerr | 5055 | request portal (the thing family asks for movies with) |
| Sonarr | 8989 | TV — monitors, grabs, renames, imports |
| Radarr | 7878 | movies — same |
| Lidarr | 8686 | music — same |
| Prowlarr | 9696 | indexer manager, syncs indexers into the other *arrs |
| Bazarr | 6767 | subtitles for what Sonarr/Radarr import |
| LazyLibrarian | 5299 | books/audiobooks/magazines automation — the Readarr substitute |
| Kapowarr | 5656 | comics automation — monitors series, fetches issues for Kavita |
| qBittorrent | 8080 | download client — the image runs **qbittorrent-nox** (headless daemon; the web UI is its only interface) |
| FlareSolverr | 8191 | solves Cloudflare challenges for Prowlarr |
| Gluetun (optional) | — | VPN tunnel + kill switch in front of qBittorrent |

## Storage design

Two virtual disks on `vm-pool` (Ceph RBD):

- **scsi0, 32 GB** — OS, Docker, and all app configs
  (`/opt/servarr/config`). Small, fast, included in vzdump backups.
- **scsi1, ~5 TB (thin)** — one big XFS filesystem at `/mnt/data`,
  **excluded** from vzdump (`backup=0` — you don't want 5 TB backups;
  the media is re-acquirable, the replication already survives hardware
  death).

Everything media-related lives under the single `/mnt/data` filesystem
in the TRaSH-guides layout, so a finished download is **hardlinked**
into the library instantly — no copy, no double disk usage, seeding
continues:

```
/mnt/data
├── torrents/{movies,tv,music,audiobooks}       ← qBittorrent writes here
└── media/{movies,tv,music,audiobooks,podcasts} ← libraries live here
```

Why an RBD data disk instead of CephFS? The VM sits on the LAN and can't
reach the Ceph mesh (10.10.10.x), so it can't mount CephFS directly —
and a block disk is fully supported by live migration and HA with zero
extra plumbing. Single consumer is fine because *this VM is* the media
stack; if something else ever needs the files, add a Samba/NFS container
here rather than a second mount elsewhere.

## 1. Create the VM

On any cluster node (settings in `scripts/cluster.env` — VMID 200,
6 cores, 16 GB RAM, IP 10.0.0.20):

```bash
bash scripts/10-create-servarr-vm.sh          # or --ha to enroll in HA now
```

The script downloads the Debian 13 cloud image, creates the VM with both
disks, and injects your SSH key + static IP via cloud-init. First boot
takes a minute (cloud-init runs a package upgrade).

## 2. Bootstrap inside the VM

```bash
# from a cluster node (or anywhere with the key):
scp -r servarr media@10.0.0.20:~
ssh media@10.0.0.20
cd servarr && sudo bash bootstrap.sh
```

Installs Docker, formats the 5 TB disk as XFS and mounts it at
`/mnt/data`, creates the directory tree, and generates `.env` from the
example. **Log out and back in** (docker group), review `.env`
(timezone; VPN credentials if you'll use the VPN overlay).

## 3. Start the stack

```bash
docker compose up -d
# or, with the VPN in front of qBittorrent (recommended for torrents):
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
```

## 4. First-run checklist (order matters)

Work through `http://10.0.0.20:<port>` for each service:

1. **qBittorrent** (8080) — temporary admin password is in
   `docker logs qbittorrent`; set a real one (*Tools → Options →
   Web UI*). Set *Default Save Path* to `/data/torrents`, and
   per-category paths: `movies` → `/data/torrents/movies`, `tv` →
   `/data/torrents/tv`, `music` → `/data/torrents/music`.
2. **Prowlarr** (9696) — set auth; add your indexers. Under *Settings →
   Indexers* add FlareSolverr: `http://flaresolverr:8191` (tag indexers
   that need it).
3. **Sonarr** (8989) — *Settings → Media Management*: add root folder
   `/data/media/tv`. *Download Clients*: qBittorrent, host `qbittorrent`
   (⚠ host `gluetun` if you use the VPN overlay), port 8080, category
   `tv`. Confirm *Settings → Importing → Use Hardlinks* is on (default).
4. **Radarr** (7878) — same, with root folder `/data/media/movies` and
   category `movies`.
5. **Lidarr** (8686) — same, with root folder `/data/media/music` and
   category `music`.
6. Back in **Prowlarr** — *Settings → Apps*: add Sonarr
   (`http://sonarr:8989` + its API key from *Settings → General*),
   Radarr (`http://radarr:7878`), and Lidarr (`http://lidarr:8686`).
   Prowlarr now pushes all indexers to all three.
7. **Bazarr** (6767) — connect Sonarr and Radarr (same URLs/API keys),
   pick subtitle providers and languages.
8. **Jellyfin** (8096) — run the wizard; add libraries: *Movies* →
   `/data/media/movies`, *Shows* → `/data/media/tv`, *Music* →
   `/data/media/music`.
9. **Jellyseerr** (5055) — sign in with Jellyfin, connect Sonarr and
   Radarr (URLs + API keys, default profiles/root folders). Family
   requests → auto-download → appears in Jellyfin. (Music requests
   aren't supported — add music directly in Lidarr.)
10. **Audiobookshelf** (13378) — create the admin account; add libraries
   `/audiobooks` and `/podcasts`. Audiobook acquisition has no
   Sonarr-equivalent (Readarr is retired): add **AudioBook Bay** as an
   indexer in Prowlarr (needs FlareSolverr), search from Prowlarr,
   send grabs to qBittorrent with category `audiobooks` (save path
   `/data/torrents/audiobooks`), then move/organize into
   `/data/media/audiobooks` — Audiobookshelf's *Match* tool fixes
   metadata on import.
11. **Kavita** (5000) — create the admin account; add libraries
    `/books` (type *Book*) and `/comics` (type *Comic* — Kapowarr fills
    this one automatically).
12. **LazyLibrarian** (5299) — the Readarr substitute: *Config →
    Downloaders* → qBittorrent (host `qbittorrent`/`gluetun`, category
    `books`); *Providers* → add your torznab indexers straight from
    Prowlarr (each Prowlarr indexer exposes a torznab URL + API key);
    *Processing* → destination `/data/media/books` for ebooks and
    `/data/media/audiobooks` for audio. Then add authors/books to
    monitor — grabs, imports, renames like the *arrs do.
13. **Kapowarr** (5656) — comics automation: needs a free
    [ComicVine API key](https://comicvine.gamespot.com/api/) (*Settings
    → General*); root folder is `/comics-1`, downloads land in
    `/app/temp_downloads` and import automatically. Add volumes
    (series) to monitor; Kavita's `/comics` library picks up everything
    it fetches. Note: Kapowarr sources mainly from direct-download
    services, so it works without touching the torrent stack.

## The *arr family — complete inventory

What's running, what's deliberately not, and why:

| *arr | Status here | Reason |
|------|-------------|--------|
| Sonarr (TV) | ✅ running | |
| Radarr (movies) | ✅ running | |
| Lidarr (music) | ✅ running | |
| Prowlarr (indexers) | ✅ running | feeds all of the above |
| Bazarr (subtitles) | ✅ running | companion, not technically an *arr fork |
| **Overseerr** | ❌ — **Jellyseerr instead** | Overseerr only authenticates against Plex; Jellyseerr is its fork with Jellyfin support — same UI, same features |
| **Readarr** (books/audiobooks) | ❌ retired upstream (2025) → **LazyLibrarian runs as its substitute** (step 12) | Readarr's repos are archived; LazyLibrarian is the maintained equivalent and covers magazines too. Manual fallback: Prowlarr search → qBittorrent → Audiobookshelf/Kavita |
| Kapowarr (comics) | ✅ running | the "Radarr for comics" — not an official *arr but fills that slot (step 13) |
| **Whisparr** (adult) | ⬜ present but commented | uncomment in the compose if wanted (port 6969) |

Optional companions, also commented in the compose, worth enabling
once the stack is settled (both need API keys → `.env`):

- **Unpackerr** — watches the *arrs and auto-extracts rar'd releases so
  imports never silently stall on an archive.
- **Recyclarr** — syncs [TRaSH-guides](https://trash-guides.info)
  quality profiles/custom formats into Sonarr/Radarr, so release
  selection follows best practice without hand-tuning.

## Fun extras (ErsatzTV, RomM)

- **ErsatzTV** (`tv.home.lan`) — assemble your movies/shows into
  scheduled "channels" with an XMLTV guide, then add its channels as a
  Live TV source in Jellyfin. Mounts the media library read-only.
  Configure channels in its own UI.
- **RomM** (`games.home.lan`) — catalogs retro-game ROMs from
  `/data/media/roms` (organized by platform sub-folder), with box art
  and metadata scraping. Play in-browser, or pair with the GTX 960
  desktop VM (docs/15) for emulators. Legal note: supply your own ROMs.

## Sharing the library (SMB)

`sudo bash setup-samba.sh` (in this same directory, inside the VM)
exports `/mnt/data/media` as an authenticated read-write SMB share —
used by Nextcloud's `Media` folder (docs/10) and mountable from any
laptop/TV on the LAN (`smb://10.0.0.20/media`, user `media`). The share
forces ownership to the `media` user so *arr hardlinks keep working no
matter who edits.

Containers reach each other by service name (`sonarr`, `radarr`,
`qbittorrent`…) on the compose network — never use `localhost` inside
these settings.

## Transcoding note

Ryzen desktop CPUs (non-G, pre-7000) have no iGPU, so Jellyfin
transcodes in software — an 8-core Ryzen 7 handles a couple of 1080p
transcodes fine. Prefer **direct play** (clients that speak the codec
natively) and this rarely matters. If it does: a cheap Intel Arc/UHD or
GTX card passed through to the VM is the standard fix — but PCI
passthrough pins the VM to that node (no live migration/HA), so decide
deliberately.

## Day-2 operations

- **Update everything**:
  `docker compose pull && docker compose up -d`
- **VM backups**: *Datacenter → Backup* → weekly vzdump of VMID 200
  (media disk auto-excluded). The *arrs also keep their own config
  backups under `/config/Backups`.
- **Watch disk usage**: `df -h /mnt/data` inside the VM, `ceph df` on
  the cluster. The 5 TB disk is thin-provisioned — Ceph only stores
  written blocks, but *deleted* space returns to Ceph only because
  `discard=on` is set and XFS/fstrim pass trims through (the VM runs
  `fstrim.timer` by default on Debian).
- **Grow the media disk later**: `qm disk resize 200 scsi1 +1000G` on a
  node, then inside the VM `sudo xfs_growfs /mnt/data`. Online, no
  downtime — just keep an eye on `ceph df` headroom.
- **HA**: if you didn't create with `--ha`:
  `ha-manager add vm:200 --state started`. Node dies → stack is back in
  ~2–3 minutes on a survivor.
