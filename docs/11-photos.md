# 11 — Photos: Immich

[Immich](https://immich.app) ([AGPL-3.0, github](https://github.com/immich-app/immich))
is the self-hosted Google Photos replacement: phone auto-backup, timeline,
face/object recognition (local ML — nothing leaves your house), shared
albums, memories. It gets its own VM because its ML stack is the
heaviest single service in the house.

| Item | Value |
|------|-------|
| VM | `photos` (205), 10.0.0.25, 4 cores / 8 GB |
| URL | `http://photos.home.lan` (Caddy) or `http://10.0.0.25:2283` |
| Library disk | 1 TB thin at `/mnt/photos/library` — **included in backups** |
| Mobile apps | iOS/Android "Immich", point at the server URL |

## Deploy

```bash
# on a cluster node:
bash scripts/14-create-photos-vm.sh --ha

# then:
scp -r photos cloud@10.0.0.25:~
ssh cloud@10.0.0.25
cd photos && sudo bash bootstrap.sh
# re-login, then:
docker compose up -d
```

Deliberate design choice: bootstrap **fetches Immich's official
`docker-compose.yml` and `example.env` from their latest GitHub
release** instead of vendoring a copy in this repo. Immich evolves fast
and pins exact versions of its own Postgres (with vector search) and ML
images — their compose is the single source of truth, and this way it
can't drift. Bootstrap only customizes `.env`: library path onto the
data disk, random DB password, timezone.

## First run

1. `http://10.0.0.25:2283` → create the admin account.
2. Install the mobile app → server URL `http://photos.home.lan` (works
   at home and over WireGuard) → enable auto-backup.
3. ML jobs (faces, smart search) chew CPU for a while after big
   imports — that's normal; watch *Administration → Jobs*.

## Family sharing & albums

- **Add family members** as separate Immich users (*Administration →
  Users*) — each gets private photos + their own mobile backup. Shared
  albums cross between them without duplicating storage.
- **Partner sharing** merges two people's timelines (couples with one
  library) — *Account Settings → Sharing → Partners*.
- Public/link shares work over WireGuard for showing albums to people
  off the LAN, without exposing anything to the internet.

## Importing an existing photo collection

Two ways, depending on whether you want Immich to *own* the files:

- **Managed (upload)**: point the [immich-cli](https://immich.app/docs/features/command-line-interface)
  at your old folders — `immich upload --recursive /path` — and Immich
  copies them into its library, deduplicating by hash so re-runs are
  safe.
- **External library (read-only)**: mount the old collection into the VM
  and register it as an *external library* — Immich indexes in place
  without moving anything. Good for a large archive you keep organized
  elsewhere; you manage the files, Immich just reads them.

## Transcoding & machine learning

- Immich generates thumbnails and transcodes some videos on **CPU**
  here (no GPU on this VM) — fine for a household, but big video imports
  will use cores for a while. If it ever matters, the GTX 960 could be
  bind-mounted for hardware transcode/ML, at the cost of pinning this VM
  to its node (same trade-off as the AI LXC, docs/16).
- ML features (face recognition, smart/CLIP search) run **locally** —
  no cloud, nothing leaves the house. The models download on first use
  (a few GB). Tune or disable specific ML jobs in *Administration →
  Settings → Machine Learning* if you want to cap the CPU appetite.

## Backups — Immich is not covered by the media exclusion

Unlike the servarr media disk, the photo library **is** in the weekly
vzdump (docs/09) — photos are not re-acquirable. Two layers worth
having:

1. **vzdump of VM 205** including the data disk (already the default).
2. Immich's own periodic **database dump** matters as much as the files
   — the SQL holds all your albums, faces, and metadata. Immich runs
   automatic DB backups inside its stack; confirm they land on the
   backed-up disk, and test a restore before you trust it with the only
   copy of the kids' photos.

## Operations

- **Update**: `docker compose pull && docker compose up -d` — but check
  [Immich release notes](https://github.com/immich-app/immich/releases)
  first; until 2.x it occasionally shipped breaking changes, so read
  before jumping versions.
- The library disk grows with `qm disk resize 205 scsi1 +500G` +
  `xfs_growfs /mnt/photos` like every other VM here — watch `ceph df`
  headroom, photos accumulate faster than you'd think.
- **Monitor**: add an Uptime Kuma HTTP check on `:2283` and an ntfy
  alert (docs/09) — a silently-dead backup target is worse than none.
