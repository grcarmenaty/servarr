# 14 — Wazuh: SIEM / Host Intrusion Detection

[Wazuh](https://wazuh.com) ([GPL-2.0 manager](https://github.com/wazuh/wazuh),
Apache-2.0 indexer/dashboard) is the step above fail2ban (docs/13):
agents on every node and VM stream security telemetry to a central
manager that correlates, alerts, and keeps history.

What it adds that nothing else in the stack does:

- **File integrity monitoring** — know when `/etc`, `/etc/pve`, or a
  container config changes, and who changed it
- **Log analysis & correlation** across all machines in one place
  (SSH failures, sudo use, kernel messages, Docker events)
- **Vulnerability detection** — inventories installed packages on every
  agent and flags known CVEs
- **CIS benchmark scans** — automated "is this host configured
  sanely" audits with scores and remediation hints
- MITRE ATT&CK-mapped alerting, one searchable dashboard

Honest sizing note: this is the heaviest infra service in the house
(an OpenSearch-based indexer). It earns its 8 GB on a 192 GB cluster,
but if you ever need RAM back, this VM is the first candidate to shrink
retention on — or pause entirely.

| Item | Value |
|------|-------|
| VM | `wazuh` (206), 10.0.0.26, 4 cores / 8 GB / 150 G indexer disk |
| Dashboard | `http://siem.home.lan` (Caddy) or `https://10.0.0.26` (self-signed) |
| Version | pinned in `cluster.env` (`WAZUH_VERSION`, [releases](https://github.com/wazuh/wazuh-docker/releases)) |

## Deploy

```bash
# on a cluster node:
bash scripts/15-create-wazuh-vm.sh --ha

# then:
scp -r wazuh cloud@10.0.0.26:~
ssh cloud@10.0.0.26
cd wazuh && sudo WAZUH_VERSION=4.14.6 bash bootstrap.sh
```

Bootstrap mounts the 150 G disk as Docker's data-root (so the indexer
data lands there), sets `vm.max_map_count`, clones Wazuh's **official
`wazuh-docker` single-node deployment** at the pinned tag, generates
the indexer certs, and starts the stack. First start takes several
minutes.

**Immediately change the default credentials** (`admin` /
`SecretPassword`): follow the
[official password procedure](https://documentation.wazuh.com/current/deployment-options/docker/wazuh-container.html#change-pwd-existing-usr)
— it's a config change + restart, not just a UI click.

## Enroll agents

Same script everywhere — Proxmox nodes, VMs, even LXCs:

```bash
# on each node (from /root/scripts):
bash 25-install-wazuh-agent.sh

# in each VM (servarr, cloud-data, cloud1/2, photos):
scp scripts/25-install-wazuh-agent.sh cloud@10.0.0.20:/tmp/ && ssh ... sudo bash /tmp/25-...

# in the LXCs:
pct push 101 scripts/25-install-wazuh-agent.sh /root/agent.sh && pct exec 101 -- bash /root/agent.sh
```

Agents self-enroll to 10.0.0.26 and appear under *Agents* in the
dashboard within a minute. The script `apt-mark hold`s the agent so it
only upgrades when you upgrade the manager (agents must not run newer
than the manager).

## What to actually look at (first month)

1. *Agents* — everything green and reporting.
2. *Vulnerability Detection* — expect noise at first; triage the
   criticals, ignore the rest until patch day.
3. *Security Configuration Assessment* — run the CIS benchmark per
   host once, fix the cheap findings, accept the deliberate ones
   (this is a homelab, not a bank).
4. *Security Events* — after a week of baseline, skim weekly. Wire
   level-12+ alerts to ntfy via an integration if you want pushes.

## Upgrades

Pinned deliberately. To move: update `WAZUH_VERSION` in `cluster.env`,
then on the VM follow the
[official upgrade doc](https://documentation.wazuh.com/current/deployment-options/docker/upgrading-wazuh-docker.html)
(new tag checkout + compose up), then unhold/upgrade agents
(`apt-mark unhold wazuh-agent && apt upgrade`) — manager first, agents
second, always.
