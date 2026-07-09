#!/usr/bin/env bash
# Post-install setup. Run once on EVERY node after installing Proxmox VE.
# Idempotent — safe to re-run.
#
#   bash 01-post-install.sh

source "$(dirname "$0")/lib.sh"
require_root
require_pve

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

# ---------------------------------------------------------------------------
log "1/5 Switching to no-subscription apt repositories (codename: ${CODENAME})"

# Disable enterprise repos in both formats (PVE 8 .list, PVE 9 .sources)
for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    if [[ -f "$f" ]] && grep -q '^deb' "$f"; then
        sed -i 's/^deb/# deb/' "$f"
        log "  disabled $(basename "$f")"
    fi
done
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    if [[ -f "$f" ]] && ! grep -qi '^Enabled: *false' "$f"; then
        if grep -qi '^Enabled:' "$f"; then
            sed -i 's/^Enabled:.*/Enabled: false/I' "$f"
        else
            echo "Enabled: false" >> "$f"
        fi
        log "  disabled $(basename "$f")"
    fi
done

# Add pve-no-subscription repo, matching the repo format this install uses
if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
    cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
else
    echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" \
        > /etc/apt/sources.list.d/pve-no-subscription.list
fi
log "  no-subscription repo configured"

# ---------------------------------------------------------------------------
log "2/5 Updating system packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
apt-get -y install chrony lsscsi smartmontools

# ---------------------------------------------------------------------------
log "3/5 Writing cluster nodes to /etc/hosts"
for i in "${!NODE_NAMES[@]}"; do
    name="${NODE_NAMES[$i]}" ip="${NODE_IPS[$i]}"
    entry="${ip} ${name}.${DOMAIN} ${name}"
    if grep -qE "^[0-9a-fA-F:.]+[[:space:]].*\b${name}\b" /etc/hosts; then
        sed -i -E "s|^[0-9a-fA-F:.]+[[:space:]].*\b${name}\b.*|${entry}|" /etc/hosts
    else
        echo "${entry}" >> /etc/hosts
    fi
done
log "  $(grep -c "${DOMAIN}" /etc/hosts) node entries present"

# ---------------------------------------------------------------------------
log "4/5 Checking time synchronization"
systemctl enable --now chrony >/dev/null 2>&1 || true
if chronyc waitsync 20 0.1 >/dev/null 2>&1; then
    log "  chrony synchronized"
else
    warn "chrony not synchronized yet — check 'chronyc tracking' before creating the cluster"
fi

# ---------------------------------------------------------------------------
log "5/5 Subscription nag"
if [[ "${REMOVE_SUBSCRIPTION_NAG}" == "yes" ]]; then
    JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    if [[ -f "$JS" ]] && grep -q "res === null || res === undefined" "$JS"; then
        sed -i "s/res === null || res === undefined || \!res || res/false \&\& res/" "$JS" || true
        systemctl restart pveproxy
        log "  nag disabled (clear browser cache to see effect)"
    else
        log "  nag already disabled or pattern changed — skipping"
    fi
    # reapply automatically when proxmox-widget-toolkit gets upgraded
    cat > /etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "test -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js && sed -i 's/res === null || res === undefined || \!res || res/false \&\& res/' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js || true"; };
EOF
else
    log "  skipped (REMOVE_SUBSCRIPTION_NAG=no)"
fi

echo
log "Post-install complete on $(hostname)."
echo "Next: configure the Ceph NIC (docs/02-network.md), verify pings,"
echo "then form the cluster with 02-create-cluster.sh (docs/04-cluster.md)."
