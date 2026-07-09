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

## Operations

- **Update**: `docker compose pull && docker compose up -d` — but check
  [Immich release notes](https://github.com/immich-app/immich/releases)
  first; until 2.x it occasionally shipped breaking changes.
- Existing photo folders can be bulk-imported with the
  [immich-cli](https://immich.app/docs/features/command-line-interface),
  or exposed read-only as an *external library*.
- The library disk grows with `qm disk resize 205 scsi1 +500G` +
  `xfs_growfs /mnt/photos` like every other VM here.
