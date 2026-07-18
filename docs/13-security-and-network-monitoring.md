# 13 — Security & Network Monitoring

What protects this platform, what watches it, and where the honest
limits are. Scripts: `21-harden-nodes.sh` (every node),
`22-enable-firewall.sh` (once), `23-install-ntopng.sh` (every node).

## Threat model, briefly

A home server's realistic threats, in order: **(1)** commodity internet
scanning/bots, **(2)** a compromised or malicious app *inside* a guest
(a bad container image, a torrent client exploit), **(3)** physical
disk theft/disposal, **(4)** a compromised device already on the LAN
(someone's laptop, a cheap IoT gadget). Nation-states are not in scope;
pretending otherwise produces unusable setups.

## Layers already in place (recap)

| Layer | Mechanism | Covers threat |
|-------|-----------|---------------|
| Attack surface | **one** inbound port (WireGuard UDP 51820); no service port-forwarded, ever | 1 |
| Remote access | WireGuard, key-based, per-device configs + PSK | 1 |
| At rest | LUKS-encrypted OSDs (docs/05 §4) | 3 |
| Guest isolation | VMs for Docker/internet-facing stacks; unprivileged LXCs for infra | 2 |
| Torrent path | gluetun kill-switch namespace → PIA VPN (outbound privacy) | 2 |
| Patching | unattended security upgrades in every guest; deliberate node updates (docs/09) | 1, 2 |
| Auth | unique passwords per service; *arr auth enabled; SMB authenticated | 4 |
| Blast radius | per-service guests — Jellyfin exploit ≠ Nextcloud data | 2 |

## New layer: node hardening (`21-harden-nodes.sh`, per node)

**fail2ban** with jails for `sshd` and the Proxmox login
(`pvedaemon` auth failures, via journald): brute-force sources get
banned for an hour after a few failures. The LAN, mesh, and WireGuard
subnets are in `ignoreip` — you can't lock yourself out by typo.

Manual follow-up worth doing once your SSH keys are proven: disable
password SSH on the nodes (the script prints the two lines).

## New layer: Proxmox cluster firewall (`22-enable-firewall.sh`, once)

Host-level, default-DROP inbound **on the nodes**: only the Ceph mesh,
cluster peers, ICMP, and management ports (8006/22/3000) from the LAN
survive. Guest traffic is untouched — this protects the hypervisors
themselves from anything weird on the LAN (threat 4).

- The script prints the rules and asks before enabling; recovery from a
  lockout is `pve-firewall stop` on any node's physical console.
- Per-guest firewalls (Datacenter → Firewall on a VM NIC) remain off.
  Turn them on selectively if you ever host something you distrust —
  the natural first candidate is blocking the servarr VM from reaching
  the LAN beyond what it needs.
- Deeper segmentation (IoT/guest VLANs) is a *router/switch* project,
  not a cluster one — worth doing if your router supports VLANs; the
  cluster side is just VLAN-tagged bridges when that day comes.

## Network monitoring

Three complementary views, all self-hosted:

### 1. ntopng — packet-level (`23-install-ntopng.sh`, per node)

[ntopng](https://www.ntop.org/products/traffic-analysis/ntop/)
(GPL-3.0 community edition) capturing on `vmbr0`: live per-host,
per-flow, per-protocol traffic — who's talking to whom, top talkers,
DPI protocol breakdown, historical graphs.

**Honest scope:** each node's ntopng sees the traffic of *the guests
on that node* (plus that node's own). It does **not** see LAN devices
talking directly to the internet — that traffic goes through your
router, not through the cluster. Whole-LAN packet visibility requires
one of: ntopng **on the router** (easy if it runs OpenWrt), a managed
switch with a mirror port, or routing the LAN through a firewall VM
(OPNsense — a real project, catalogued in docs/12). For a homelab, the
per-node view + DNS view below covers 90% of the questions you'll
actually ask.

UI: `http://node1:3000` (also `http://traffic.home.lan` → node1), login
`admin/admin` on first run, forced change. RAM cost ~0.5–1 GB per node —
budgeted headroom absorbs it.

### 2. AdGuard Home — DNS-level (already deployed)

The query log at `http://dns.home.lan` is whole-LAN visibility the
router can't hide: **every device** using your DHCP-served DNS shows
every domain it resolves — the chatty TV, the phone app phoning home,
the IoT gadget calling China at 3am. *Settings → Query log* (bump
retention to 30–90 days) and *Top clients / Top requested domains* are
the fastest "what is my network doing" answer in the house. Blocking a
misbehaving device's domains is one click from the same screen.

### 3. Uptime Kuma + ntfy — liveness and alerting (already deployed)

Kuma watches that things are *up*; ntopng/AdGuard watch what things
*do*. Alerts land on your phone via self-hosted ntfy (docs/09).

## Worth adding later (catalogued in docs/12)

- **CrowdSec** (MIT) — collaborative IPS: parses logs like fail2ban but
  shares/consumes crowd-sourced ban lists. Overkill while only WG 51820
  is exposed; becomes interesting if you ever publish a service.
- **OPNsense/pfSense VM as the LAN router** — the full answer to
  whole-LAN visibility + VLANs + IDS (Suricata). A weekend project and
  a topology change; do it when the ISP router annoys you enough.
- **LibreNMS** (GPL-3.0) — SNMP polling/graphing of router, switches,
  nodes. Valuable once you own a managed switch.

## The security checklist that actually matters

1. One exposed port (WG). Check with your router's port-forward list —
   and re-check after any router firmware update resets things.
2. Router hygiene: **UPnP off** (apps silently opening ports defeats
   item 1), WPA3/WPA2 with a real passphrase, admin UI not reachable
   from WAN, guest Wi-Fi for visitors/IoT.
3. Unique admin passwords everywhere; a password manager (you host
   Vaultwarden) makes this free.
4. Backups you've **test-restored** (docs/09) — ransomware's only real
   antidote.
5. Update cadence: guests are automatic; nodes monthly, one at a time.
6. Once a quarter, skim AdGuard's top-domains and ntopng's top talkers
   for anything you don't recognize. Ten minutes, catches the weird.
