# 12 — Software Catalog & Open-Source Audit

Everything this platform runs, with license, source repository, and
project site. **Audit verdict: the entire stack is free and open-source
software** — every license below is OSI-approved (GPL/AGPL/LGPL, Apache,
MIT, BSD, MPL, PostgreSQL). One component was *replaced* to keep that
true, and a few *optional external services* are flagged at the bottom.

**The one fix the audit forced:** Redis changed to non-open licenses
(RSALv2/SSPL) from v7.4 in 2024, which made the `redis:7` Docker tag a
license lottery. This stack uses **Valkey** instead — the Linux
Foundation's BSD-3 fork, protocol-identical. (Redis 8 later re-added an
AGPL option, but Valkey is the clean community answer.)

## Platform (runs on the metal)

| Software | Role | License | Source | Site/Docs |
|----------|------|---------|--------|-----------|
| Proxmox VE | hypervisor + cluster | AGPL-3.0 | [git.proxmox.com](https://git.proxmox.com) | [proxmox.com](https://www.proxmox.com/en/products/proxmox-virtual-environment/overview) · [wiki](https://pve.proxmox.com/wiki/Main_Page) |
| Ceph | distributed storage | LGPL-2.1/3.0 | [github.com/ceph/ceph](https://github.com/ceph/ceph) | [ceph.io](https://ceph.io) · [docs](https://docs.ceph.com) |
| Debian | OS (nodes, VMs, LXCs) | DFSG-free | [salsa.debian.org](https://salsa.debian.org) | [debian.org](https://www.debian.org) |
| Corosync | cluster membership/quorum | BSD-3 | [github.com/corosync/corosync](https://github.com/corosync/corosync) | [wiki](https://corosync.github.io/corosync/) |
| cryptsetup/LUKS | OSD encryption at rest | GPL-2.0+ | [gitlab.com/cryptsetup/cryptsetup](https://gitlab.com/cryptsetup/cryptsetup) | [docs](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home) |
| chrony | time sync (Ceph needs it) | GPL-2.0 | [gitlab.com/chrony/chrony](https://gitlab.com/chrony/chrony) | [chrony-project.org](https://chrony-project.org) |
| Docker Engine + Compose | container runtime in VMs | Apache-2.0 | [github.com/moby/moby](https://github.com/moby/moby) · [docker/compose](https://github.com/docker/compose) | [docs.docker.com](https://docs.docker.com) |
| cloud-init | VM first-boot config | GPL-3.0/Apache-2.0 | [github.com/canonical/cloud-init](https://github.com/canonical/cloud-init) | [docs](https://cloudinit.readthedocs.io) |
| Proxmox Backup Server *(planned, docs/09)* | dedup backups | AGPL-3.0 | [git.proxmox.com](https://git.proxmox.com/?p=proxmox-backup.git) | [proxmox.com/pbs](https://www.proxmox.com/en/products/proxmox-backup-server/overview) |
| NUT *(when UPS arrives)* | UPS monitoring/shutdown | GPL-2.0+ | [github.com/networkupstools/nut](https://github.com/networkupstools/nut) | [networkupstools.org](https://networkupstools.org) |
| fail2ban | SSH/UI brute-force bans | GPL-2.0+ | [github.com/fail2ban/fail2ban](https://github.com/fail2ban/fail2ban) | [docs](https://fail2ban.readthedocs.io) |
| Proxmox VE firewall | host-level packet filter | AGPL-3.0 (part of PVE) | [git.proxmox.com](https://git.proxmox.com/?p=pve-firewall.git) | [wiki](https://pve.proxmox.com/wiki/Firewall) |
| ntopng (community) | network traffic analysis per node | GPL-3.0 | [github.com/ntop/ntopng](https://github.com/ntop/ntopng) | [ntop.org](https://www.ntop.org/products/traffic-analysis/ntop/) · [docs](https://www.ntop.org/guides/ntopng/) |
| Wazuh | SIEM / host IDS / vuln detection | GPL-2.0 (manager); Apache-2.0 (indexer/dashboard) | [github.com/wazuh/wazuh](https://github.com/wazuh/wazuh) · [wazuh-docker](https://github.com/wazuh/wazuh-docker) | [wazuh.com](https://wazuh.com) · [docs](https://documentation.wazuh.com) |
| Apache Guacamole | browser RDP/VNC/SSH portal | Apache-2.0 | [github.com/apache/guacamole-server](https://github.com/apache/guacamole-server) | [guacamole.apache.org](https://guacamole.apache.org) |
| xrdp | RDP server in desktop VMs | Apache-2.0 | [github.com/neutrinolabs/xrdp](https://github.com/neutrinolabs/xrdp) | [xrdp.org](http://xrdp.org) |
| Xfce | desktop environment in desktop VMs | GPL/LGPL | [gitlab.xfce.org](https://gitlab.xfce.org) | [xfce.org](https://xfce.org) |
| noVNC / SPICE | in-browser + rich VM consoles (part of PVE) | MPL-2.0 / LGPL | [github.com/novnc/noVNC](https://github.com/novnc/noVNC) · [spice-space.org](https://www.spice-space.org) | [virt-viewer](https://virt-manager.org) |

## AI tier (VM 207 *or* LXC 108, CPU by default)

Runs as either a Docker VM (`scripts/16`) or a native LXC
(`scripts/17`) — same software, see docs/16 for the trade-off. The LXC
path installs Ollama via its official script and Open WebUI + the voice
services from PyPI (all the same projects/licenses below).


| Software | Role | License | Source | Site/Docs |
|----------|------|---------|--------|-----------|
| Ollama | LLM inference server (CPU, optional GPU) | MIT | [github.com/ollama/ollama](https://github.com/ollama/ollama) | [ollama.com](https://ollama.com) |
| llama.cpp | inference engine under Ollama | MIT | [github.com/ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | — |
| Open WebUI | authenticated chat UI + OpenAI-compatible API | ⚠ "Open WebUI License" — BSD-3 **plus a branding-protection clause** (≥ v0.6); not OSI-listed. Functionally open; the one licensing asterisk in the stack. Pure-MIT alternative: [LibreChat](https://github.com/danny-avila/LibreChat) | [github.com/open-webui/open-webui](https://github.com/open-webui/open-webui) | [docs.openwebui.com](https://docs.openwebui.com) |
| Wyoming Whisper | local speech-to-text (Home Assistant voice) | MIT | [github.com/rhasspy/wyoming-faster-whisper](https://github.com/rhasspy/wyoming-faster-whisper) | [rhasspy](https://github.com/rhasspy) |
| Wyoming Piper | local text-to-speech | MIT | [github.com/rhasspy/wyoming-piper](https://github.com/rhasspy/wyoming-piper) | [piper samples](https://rhasspy.github.io/piper-samples/) |
| nvidia-container-toolkit *(only if the 960 is attached)* | GPU access for containers | Apache-2.0 | [github.com/NVIDIA/nvidia-container-toolkit](https://github.com/NVIDIA/nvidia-container-toolkit) | [docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/) |
| NVIDIA driver + CUDA *(optional GPU path only)* | GPU driver/runtime | **proprietary** — the only non-FOSS software component, and now **fully optional**: the default CPU path uses none of it | [nvidia.com/drivers](https://www.nvidia.com/en-us/drivers/) | flagged deliberately |

## Core services (LXCs 101–106)

| Software | Role | License | Source | Site/Docs |
|----------|------|---------|--------|-----------|
| AdGuard Home (×2) | DNS + ad blocking | GPL-3.0 | [github.com/AdguardTeam/AdGuardHome](https://github.com/AdguardTeam/AdGuardHome) | [adguard.com/adguard-home](https://adguard.com/en/adguard-home/overview.html) · [wiki](https://github.com/AdguardTeam/AdGuardHome/wiki) |
| Caddy | reverse proxy + portal | Apache-2.0 | [github.com/caddyserver/caddy](https://github.com/caddyserver/caddy) | [caddyserver.com](https://caddyserver.com/docs/) |
| WireGuard | remote-access VPN | GPL-2.0 (kernel) | [git.zx2c4.com](https://git.zx2c4.com/wireguard-linux/) | [wireguard.com](https://www.wireguard.com) |
| Uptime Kuma | monitoring + alerting | MIT | [github.com/louislam/uptime-kuma](https://github.com/louislam/uptime-kuma) | [wiki](https://github.com/louislam/uptime-kuma/wiki) |
| ntfy | self-hosted push notifications | Apache-2.0 / GPL-2.0 | [github.com/binwiederhier/ntfy](https://github.com/binwiederhier/ntfy) | [ntfy.sh](https://ntfy.sh) · [docs](https://docs.ntfy.sh) |
| Forgejo | self-hosted git + CI | GPL-3.0+ | [codeberg.org/forgejo/forgejo](https://codeberg.org/forgejo/forgejo) | [forgejo.org](https://forgejo.org/docs/) |

## Media stack (servarr VM, 200)

| Software | Role | License | Source | Site/Docs |
|----------|------|---------|--------|-----------|
| Jellyfin | media server | GPL-2.0 | [github.com/jellyfin/jellyfin](https://github.com/jellyfin/jellyfin) | [jellyfin.org](https://jellyfin.org/docs/) |
| Jellyseerr | request portal | MIT | [github.com/fallenbagel/jellyseerr](https://github.com/fallenbagel/jellyseerr) | [docs.jellyseerr.dev](https://docs.jellyseerr.dev) |
| Sonarr | TV automation | GPL-3.0 | [github.com/Sonarr/Sonarr](https://github.com/Sonarr/Sonarr) | [sonarr.tv](https://sonarr.tv) · [wiki](https://wiki.servarr.com/sonarr) |
| Radarr | movie automation | GPL-3.0 | [github.com/Radarr/Radarr](https://github.com/Radarr/Radarr) | [radarr.video](https://radarr.video) · [wiki](https://wiki.servarr.com/radarr) |
| Lidarr | music automation | GPL-3.0 | [github.com/Lidarr/Lidarr](https://github.com/Lidarr/Lidarr) | [lidarr.audio](https://lidarr.audio) · [wiki](https://wiki.servarr.com/lidarr) |
| Unpackerr *(commented)* | auto-extract rar'd downloads | MIT | [github.com/Unpackerr/unpackerr](https://github.com/Unpackerr/unpackerr) | [unpackerr.zip](https://unpackerr.zip) |
| Recyclarr *(commented)* | TRaSH profile sync for Sonarr/Radarr | MIT | [github.com/recyclarr/recyclarr](https://github.com/recyclarr/recyclarr) | [recyclarr.dev](https://recyclarr.dev) |
| Whisparr *(commented)* | the adult *arr | GPL-3.0 | [github.com/Whisparr/Whisparr](https://github.com/Whisparr/Whisparr) | [wiki](https://wiki.servarr.com/whisparr) |
| Prowlarr | indexer manager | GPL-3.0 | [github.com/Prowlarr/Prowlarr](https://github.com/Prowlarr/Prowlarr) | [wiki](https://wiki.servarr.com/prowlarr) |
| Bazarr | subtitles | GPL-3.0 | [github.com/morpheus65535/bazarr](https://github.com/morpheus65535/bazarr) | [bazarr.media](https://www.bazarr.media) · [wiki](https://wiki.bazarr.media) |
| qBittorrent | torrent download client | GPL-2.0+ | [github.com/qbittorrent/qBittorrent](https://github.com/qbittorrent/qBittorrent) | [qbittorrent.org](https://www.qbittorrent.org) |
| NZBGet | Usenet download client | GPL-2.0 | [github.com/nzbgetcom/nzbget](https://github.com/nzbgetcom/nzbget) (maintained fork) | [nzbget.com](https://nzbget.com) |
| Gluetun | VPN container + kill switch | MIT | [github.com/qdm12/gluetun](https://github.com/qdm12/gluetun) | [wiki](https://github.com/qdm12/gluetun-wiki) |
| FlareSolverr | Cloudflare challenge solver | MIT | [github.com/FlareSolverr/FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) | — |
| Audiobookshelf | audiobooks + podcasts | GPL-3.0 | [github.com/advplyr/audiobookshelf](https://github.com/advplyr/audiobookshelf) | [audiobookshelf.org](https://www.audiobookshelf.org) |
| Kavita | ebooks, comics, manga | GPL-3.0 | [github.com/Kareadita/Kavita](https://github.com/Kareadita/Kavita) | [kavitareader.com](https://www.kavitareader.com) · [wiki](https://wiki.kavitareader.com) |
| LazyLibrarian | books/audiobooks automation (Readarr substitute) | GPL-3.0 | [gitlab.com/LazyLibrarian/LazyLibrarian](https://gitlab.com/LazyLibrarian/LazyLibrarian) | [docs](https://lazylibrarian.gitlab.io) |
| Kapowarr | comics automation | GPL-3.0 | [github.com/Casvt/Kapowarr](https://github.com/Casvt/Kapowarr) | [docs](https://casvt.github.io/Kapowarr/) |
| ErsatzTV | live TV channels from the library | Zlib | [github.com/ErsatzTV/ErsatzTV](https://github.com/ErsatzTV/ErsatzTV) | [ersatztv.org](https://ersatztv.org) |
| RomM | retro-game ROM library manager | AGPL-3.0 | [github.com/rommapp/romm](https://github.com/rommapp/romm) | [docs.romm.app](https://docs.romm.app) |
| Samba | SMB share of the library | GPL-3.0 | [gitlab.com/samba-team](https://gitlab.com/samba-team/samba) | [samba.org](https://www.samba.org) |
| LinuxServer.io images | container packaging | GPL-3.0 | [github.com/linuxserver](https://github.com/linuxserver) | [linuxserver.io](https://www.linuxserver.io) · [docs](https://docs.linuxserver.io) |

## Cloud tier (VMs 202–204) & photos (205)

| Software | Role | License | Source | Site/Docs |
|----------|------|---------|--------|-----------|
| Nextcloud | files/calendar/contacts (×2 app servers) | AGPL-3.0 | [github.com/nextcloud/server](https://github.com/nextcloud/server) | [nextcloud.com](https://nextcloud.com) · [docs](https://docs.nextcloud.com) |
| PostgreSQL 17 | database | PostgreSQL License | [git.postgresql.org](https://git.postgresql.org/gitweb/?p=postgresql.git) | [postgresql.org](https://www.postgresql.org/docs/) |
| **Valkey** (not Redis — see audit note) | cache/sessions/locks | BSD-3 | [github.com/valkey-io/valkey](https://github.com/valkey-io/valkey) | [valkey.io](https://valkey.io) |
| Firefly III | personal finance | AGPL-3.0 | [github.com/firefly-iii/firefly-iii](https://github.com/firefly-iii/firefly-iii) | [firefly-iii.org](https://www.firefly-iii.org) · [docs](https://docs.firefly-iii.org) |
| Firefly Data Importer | bank/CSV imports | AGPL-3.0 | [github.com/firefly-iii/data-importer](https://github.com/firefly-iii/data-importer) | [docs](https://docs.firefly-iii.org/how-to/data-importer/) |
| Paperless-ngx | document archive + OCR | GPL-3.0 | [github.com/paperless-ngx/paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) | [docs.paperless-ngx.com](https://docs.paperless-ngx.com) |
| Immich | photo backup + ML search | AGPL-3.0 | [github.com/immich-app/immich](https://github.com/immich-app/immich) | [immich.app](https://immich.app) · [docs](https://immich.app/docs) |
| SearXNG | private metasearch engine | AGPL-3.0 | [github.com/searxng/searxng](https://github.com/searxng/searxng) | [docs.searxng.org](https://docs.searxng.org) |
| Taiga | agile project management (kanban/scrum) | AGPL-3.0 (back) / MPL-2.0 (front) | [github.com/taigaio](https://github.com/taigaio) · [taiga-docker](https://github.com/taigaio/taiga-docker) | [taiga.io](https://taiga.io) · [docs](https://docs.taiga.io) |
| Karakeep | bookmarks / read-it-later, AI tagging | AGPL-3.0 | [github.com/karakeep-app/karakeep](https://github.com/karakeep-app/karakeep) | [karakeep.app](https://karakeep.app) |
| Meilisearch | search backend (Karakeep) | MIT | [github.com/meilisearch/meilisearch](https://github.com/meilisearch/meilisearch) | [meilisearch.com](https://www.meilisearch.com) |
| Mealie | recipes + meal planning | AGPL-3.0 | [github.com/mealie-recipes/mealie](https://github.com/mealie-recipes/mealie) | [mealie.io](https://mealie.io) |
| Grocy | groceries / chores / household ERP | MIT | [github.com/grocy/grocy](https://github.com/grocy/grocy) | [grocy.info](https://grocy.info) |
| Homebox | home inventory | AGPL-3.0 | [github.com/sysadminsmedia/homebox](https://github.com/sysadminsmedia/homebox) | [homebox.software](https://homebox.software) |
| FreshRSS | RSS/news reader | AGPL-3.0 | [github.com/FreshRSS/FreshRSS](https://github.com/FreshRSS/FreshRSS) | [freshrss.org](https://freshrss.org) |
| ArchiveBox | permanent local web archive | MIT | [github.com/ArchiveBox/ArchiveBox](https://github.com/ArchiveBox/ArchiveBox) | [archivebox.io](https://archivebox.io) |
| BookStack | household wiki | MIT | [github.com/BookStackApp/BookStack](https://github.com/BookStackApp/BookStack) | [bookstackapp.com](https://www.bookstackapp.com) |
| Conduit | Matrix chat server (federation off) | Apache-2.0 | [gitlab.com/famedly/conduit](https://gitlab.com/famedly/conduit) | [conduit.rs](https://conduit.rs) |
| Element Web | Matrix client | AGPL-3.0 | [github.com/element-hq/element-web](https://github.com/element-hq/element-web) | [element.io](https://element.io) |
| MariaDB | database (BookStack, RomM) | GPL-2.0 | [github.com/MariaDB/server](https://github.com/MariaDB/server) | [mariadb.org](https://mariadb.org) |
| NFS (nfs-kernel-server) | shared Nextcloud state | GPL-2.0 | [git.kernel.org](https://git.kernel.org) | [linux-nfs.org](https://linux-nfs.org) |
| Vaultwarden *(extra)* | Bitwarden-compatible passwords | AGPL-3.0 | [github.com/dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden) | [wiki](https://github.com/dani-garcia/vaultwarden/wiki) |
| Syncthing *(extra)* | device file sync | MPL-2.0 | [github.com/syncthing/syncthing](https://github.com/syncthing/syncthing) | [syncthing.net](https://syncthing.net) · [docs](https://docs.syncthing.net) |
| Home Assistant OS *(optional)* | smart home | Apache-2.0 | [github.com/home-assistant](https://github.com/home-assistant/core) | [home-assistant.io](https://www.home-assistant.io) |

## Guides this build leans on

- [TRaSH Guides](https://trash-guides.info) — the *arr/qBittorrent
  hardlink layout ([github](https://github.com/TRaSH-Guides/Guides), MIT)
- [Proxmox wiki: Full Mesh Network for Ceph](https://pve.proxmox.com/wiki/Full_Mesh_Network_for_Ceph_Server)
  — the switchless 10 GbE triangle
- [Proxmox wiki: High Availability](https://pve.proxmox.com/wiki/High_Availability)

## External services (optional, NOT self-hosted software — flagged honestly)

| Service | Used for | Nature |
|---------|----------|--------|
| [Enable Banking](https://enablebanking.com) | Firefly bank sync (PSD2 aggregator) | commercial SaaS, free restricted tier; **optional** — CSV import is the FOSS-only path |
| [GoCardless Bank Account Data](https://gocardless.com/bank-account-data/) | legacy bank sync | commercial SaaS, winding down |
| [Private Internet Access (PIA)](https://www.privateinternetaccess.com) | torrent-client outbound privacy (via Gluetun) | commercial VPN subscription; the Gluetun client wrapping it is MIT/FOSS. Scoped to qBittorrent only — see docs/08 |
| DDNS (e.g. [DuckDNS](https://www.duckdns.org)) | WireGuard endpoint | free service; self-host alternative: your own domain + DNS API |
| [Quad9](https://quad9.net) / upstream DNS | AdGuard upstream | public resolver (Swiss non-profit); swap freely |

Nothing in the platform *requires* any of these — drop them and
everything still runs, minus that convenience.

## Evaluated for later (all FOSS unless flagged, deliberately not installed yet)

Capacity reality check before adding from this list: ~57 GB of HA-protected
RAM against ~80 GB two-survivor headroom means roughly **15–20 GB of
comfortable HA budget left** (pinned/experimental guests can go beyond —
they don't need absorbing). cloud-data (8 GB) comfortably takes 2–3 more
small web apps; heavier/ML tools want a dedicated GPU the cluster
doesn't have (the 4 GB GTX 960 is too small for image gen).

| Software | What | License | Links | Why not yet |
|----------|------|---------|-------|-------------|
| Frigate | NVR / camera AI | MIT | [github](https://github.com/blakeblackshear/frigate) · [frigate.video](https://frigate.video) | needs cameras + ideally a Coral/iGPU |
| Navidrome | music streaming (Subsonic API) | GPL-3.0 | [github](https://github.com/navidrome/navidrome) · [navidrome.org](https://www.navidrome.org) | Jellyfin already serves music; add if you want Subsonic apps |
| Grafana + Prometheus | deep metrics/dashboards | AGPL-3.0 / Apache-2.0 | [grafana](https://github.com/grafana/grafana) · [prometheus](https://github.com/prometheus/prometheus) | Proxmox graphs + Kuma cover the need; add for fun |
| Headscale | self-hosted Tailscale control plane | BSD-3 | [github](https://github.com/juanfont/headscale) | WireGuard covers remote access; relevant if CGNAT ever forces Tailscale-style NAT traversal |
| CrowdSec | collaborative IPS | MIT | [github](https://github.com/crowdsecurity/crowdsec) · [crowdsec.net](https://www.crowdsec.net) | overkill with one exposed UDP port; add if you ever publish services |
| OPNsense | firewall/router OS (VLANs, Suricata IDS, whole-LAN visibility) | BSD-2 | [github](https://github.com/opnsense/core) · [opnsense.org](https://opnsense.org) | replaces the ISP router — a project of its own (docs/13) |
| LibreNMS | SNMP network monitoring | GPL-3.0 | [github](https://github.com/librenms/librenms) · [librenms.org](https://www.librenms.org) | valuable once a managed switch exists |
| Pi-hole | AdGuard alternative | EUPL-1.2 | [github](https://github.com/pi-hole/pi-hole) · [pi-hole.net](https://pi-hole.net) | AdGuard Home chosen (single binary, DoH out of the box) |
| Suwayomi | manga downloader/server (pairs with Kavita) | MPL-2.0 | [github](https://github.com/Suwayomi/Suwayomi-Server) | add to the servarr compose if manga sources beyond Kapowarr are wanted |
| ComfyUI | Stable Diffusion image generation | GPL-3.0 | [github](https://github.com/comfyanonymous/ComfyUI) | needs a real GPU (the 4 GB 960 is too small for SDXL); revisit with a bigger card |
| Crafty Controller | Minecraft server manager | GPL-3.0 (⚠ the game server itself is proprietary Mojang software) | [gitlab](https://gitlab.com/crafty-controller/crafty-4) · [craftycontrol.com](https://craftycontrol.com) | own VM, easy to make a desktop-factory sibling |

**Deliberately skipped as redundant** (already covered by something
installed): Wallabag → Karakeep does read-it-later; Navidrome →
Jellyfin serves music; Suwayomi → Kapowarr + Kavita cover comics/manga.

Placement rule of thumb when adding from this list: web app with a
database → cloud-data compose; heavy/ML → its own VM; single Go/Rust
binary infra → new LXC (copy any `scripts/core/provision-*.sh` as a
template).
