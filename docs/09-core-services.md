# 09 — Core Services: Everything Else a Home Server Should Have

The media stack (docs/08) is the fun part. This page is the platform
around it: DNS, nice URLs, remote access, monitoring, smart home,
backups, and power. Four native LXCs (no Docker — see the VM-vs-LXC
rationale in docs/08), one optional VM, and some policy.

## Service map

| Service | Guest | ID | IP | Entry point |
|---------|-------|----|----|-------------|
| AdGuard Home — DNS + ad blocking | LXC | 101 | 10.0.0.5 | `http://dns.home.lan` |
| Caddy — reverse proxy + portal | LXC | 102 | 10.0.0.6 | `http://home.lan` |
| WireGuard — remote access VPN | LXC | 103 | 10.0.0.7 | (UDP 51820) |
| Uptime Kuma — monitoring/alerts | LXC | 104 | 10.0.0.8 | `http://status.home.lan` |
| Servarr — media stack (docs/08) | VM | 200 | 10.0.0.20 | `http://jellyfin.home.lan` |
| Home Assistant OS — smart home | VM | 201 | 10.0.0.21 | `http://hass.home.lan` |
| Cloud — Nextcloud + Firefly III (docs/10) | VM | 202 | 10.0.0.22 | `http://cloud.home.lan` |

Create the LXCs (any node, after Ceph is up):

```bash
bash scripts/11-create-core-lxcs.sh all --ha
bash scripts/12-create-haos-vm.sh --ha      # optional, if you do smart home
```

The LXCs are unprivileged Debian 13 with rootfs on Ceph (so they migrate
and can be HA-protected — LXC restart-migration is fine for these),
auto-provisioned by `scripts/core/provision-*.sh`, with unattended
security updates enabled inside each. Get a shell in any of them from a
node with `pct enter <id>`.

## AdGuard Home (DNS) — finish by hand, 5 minutes

1. Open `http://10.0.0.5:3000` → wizard: web UI on port **80**, DNS on
   **53**, set admin credentials.
2. *Filters → DNS rewrites* — this is what makes all the nice hostnames
   work:

   | Domain | Answer |
   |--------|--------|
   | `*.home.lan` | 10.0.0.6 (Caddy) |
   | `home.lan` | 10.0.0.6 |
   | `node1.home.lan` | 10.0.0.11 |
   | `node2.home.lan` | 10.0.0.12 |
   | `node3.home.lan` | 10.0.0.13 |

   (The three node entries must be explicit so they beat the wildcard.)
3. *Settings → DNS settings* — upstreams: `https://dns.quad9.net/dns-query`
   or your preference; enable parallel requests.
4. **Router**: set the DHCP server's DNS option to `10.0.0.5` so every
   device on the LAN gets ad blocking and the `*.home.lan` names. Keep
   the router itself (or Quad9) as a *secondary* DNS on devices that
   must never break, if your router supports handing out two.

The infra guests deliberately keep the router as their DNS
(`LAN_DNS`) so DNS for the cluster itself never depends on AdGuard
being up.

## Caddy (reverse proxy) — nothing to do

`http://home.lan` serves a portal page linking every service; every app
gets a memorable hostname (see the map above — full list in
`scripts/core/Caddyfile`). Plain HTTP on the LAN by design: `.lan`
can't get public certificates, and self-signed ones mean warnings on
every device. If you later buy a real domain, Caddy turns all of it
into proper HTTPS with two-line changes (ACME DNS challenge) — the
Caddyfile has notes.

To add a service later: add a block to `/etc/caddy/Caddyfile` in the
container (`pct enter 102`), then `systemctl reload caddy`. Keep the
repo copy (`scripts/core/Caddyfile`) in sync — it's the source of truth
if you ever rebuild.

## WireGuard (remote access) — 3 steps to finish

1. **DDNS**: unless you have a static public IP, set up dynamic DNS
   (your router's built-in DDNS, DuckDNS, or Cloudflare) and put the
   result in `cluster.env` as `WG_ENDPOINT="yourname.duckdns.org:51820"`
   *before* provisioning — or edit `/etc/wireguard/params` in the
   container after.
2. **Router**: forward **UDP 51820** → 10.0.0.7. This is the *only*
   port your home exposes to the internet — everything else stays
   LAN/VPN-only. (If your ISP uses CGNAT, port forwarding won't work;
   use Tailscale instead — one `curl -fsSL https://tailscale.com/install.sh | sh`
   in this same container.)
3. **Per device**: `pct exec 103 -- wg-add-peer phone` — prints the
   config and a QR code to scan with the WireGuard app. Clients get
   split-tunnel access to the LAN and use AdGuard for DNS, so ad
   blocking and `*.home.lan` names work from anywhere.

## Uptime Kuma (monitoring) — first run

Open `http://10.0.0.8:3001`, create the admin account, then add
monitors — suggested set:

- **Ping**: 10.0.0.11/.12/.13 (the nodes), the router.
- **HTTP**: `http://10.0.0.20:8096` (Jellyfin), `:5055` (Jellyseerr),
  `http://10.0.0.5:80` (AdGuard), `https://10.0.0.11:8006` (Proxmox —
  enable "ignore TLS error").
- **DNS**: query type A for `google.com` against server 10.0.0.5.

Then *Settings → Notifications*: hook up Telegram, ntfy, email, or
Discord — this is the thing that texts you when Jellyfin dies while
you're on the sofa. Monitor from the outside too if you want rigor:
Kuma can't tell you the whole cluster lost power (see UPS below).

## Home Assistant (optional)

`scripts/12-create-haos-vm.sh` imports the official HAOS image as VM
201. HAOS boots via DHCP — reserve `10.0.0.21` for its MAC in the
router (the script prints the MAC), then onboard at
`http://10.0.0.21:8123`. USB Zigbee/Z-Wave sticks: plug into one node
and USB-passthrough to the VM — but note that pins the VM to that node
(disable HA for it, or buy a network coordinator like SLZB-06 to stay
migratable).

## Backups — the part everyone skips (don't)

Ceph replication survives dead hardware, not `rm -rf`, ransomware, or a
botched upgrade. Layered plan:

1. **Now (zero hardware): vzdump to CephFS.** *Datacenter → Backup →
   Add*: all guests, weekly (say Sun 03:00), storage `cephfs`, mode
   *Snapshot*, retention e.g. keep-last 3. The servarr media disk is
   already excluded (`backup=0`); everything else is small. This
   protects against guest-level disasters and still lives on the
   cluster.
2. **Soon (~€60): one USB HDD.** Plug a 4+ TB USB disk into node1, add
   as *Directory* storage, run a second weekly vzdump job to it (or
   better, install **Proxmox Backup Server** as a small VM with its
   datastore on that USB disk — deduplicated, incremental, verifiable
   backups and single-file restore).
3. **Ideal: off-site.** A second cheap box at a relative's with PBS
   remote-sync, or an encrypted rclone push of the PBS datastore to any
   cloud storage. This is the "house burns down" tier — apply judgment
   for how much of the media library merits it vs. just the configs.

App-level extras that make restores pleasant: the *arrs keep rolling
config backups (`/config/Backups`), Home Assistant makes its own
backups (Settings → System → Backups — point them at the Google Drive
add-on or download periodically), AdGuard/Caddy/WireGuard configs are
tiny files already captured by vzdump.

## Power — a UPS is not optional for Ceph

A dirty three-node power loss can leave Ceph recovering for hours (it
will recover — but why suffer). One consumer UPS (~600–900 VA per node,
or one big one if the nodes share a circuit) buys clean shutdowns:

- `apt install nut` on the node with the USB cable, configure it as the
  NUT server; other nodes run NUT clients (`netclient` mode) against it.
- Shutdown order on low battery: HA-disable → guests → nodes. Even the
  default "shut this node down at 20% battery" config is 90% of the
  value.
- Set BIOS "restore on AC power" (docs/01) so everything comes back by
  itself — the cluster, then `onboot=1` guests, in order.

## Updates policy

- **Guests (LXCs)**: security patches automatic (unattended-upgrades,
  installed by provisioning). App updates: AdGuard updates itself from
  its UI; Caddy via apt; Kuma: `cd /opt/uptime-kuma && git pull && npm
  run setup && systemctl restart uptime-kuma`.
- **Servarr VM**: `docker compose pull && docker compose up -d`
  monthly-ish; Debian security patches are automatic (cloud image
  default).
- **Proxmox nodes**: manual, deliberate, **one node at a time**: migrate
  guests off → `apt update && apt dist-upgrade` → reboot → wait for
  `ceph -s` = HEALTH_OK → next node. Never in a hurry, never two at
  once.

## Security posture (summary)

- Exactly **one** port reaches the internet: WireGuard's UDP 51820.
  Everything else — Proxmox UI included — is LAN/VPN-only. No port
  forwards for Jellyfin/qBittorrent/etc., ever; use the VPN.
- Unprivileged LXCs, VMs for anything Docker or internet-facing.
- Unique passwords on: Proxmox root, AdGuard, Kuma, qBittorrent, and
  each *arr (enable auth in their Settings → General).
- Torrent traffic goes through gluetun's kill switch (docs/08).

## Extras and where future services should go

Two ready to enable now in the servarr VM
(`servarr/docker-compose.extras.yml`): **Vaultwarden** (Bitwarden
server — needs the HTTPS Caddy block, see comments) and **Syncthing**
(device file sync). After starting them, uncomment their hostnames in
the Caddyfile.

The menu people usually add next — placement guidance:

| Service | What | Where |
|---------|------|-------|
| Immich | Google-Photos replacement | Its own compose in the cloud VM (bump its RAM for ML); photos under `/mnt/clouddata/photos` |
| Paperless-ngx | document archive | Cloud VM compose; docs under `/mnt/clouddata/documents` |
| Frigate | NVR / cameras | Own VM; wants a Coral TPU or iGPU, storage appetite is big |
| Pi-hole alternative dashboards, Grafana, etc. | | Only if you enjoy them — Kuma + Proxmox graphs cover the basics |

(Nextcloud and Firefly III graduated from this menu into their own VM —
`docs/10-cloud-stack.md`.)

Rule of thumb: Docker things go in VMs (one "apps" VM is fine until it
isn't), single-binary infra goes in LXCs, and anything with a USB
dongle costs you migratability.
