#!/usr/bin/env bash
# Create + provision the core service LXCs (docs/09-core-services.md):
#   adguard    DNS + ad blocking            10.0.0.5
#   caddy      reverse proxy + portal       10.0.0.6
#   wireguard  remote-access VPN            10.0.0.7
#   kuma       Uptime Kuma monitoring       10.0.0.8
#   adguard2   second DNS (HA pair)         10.0.0.9
#
# Run ONCE, on any cluster node, after Ceph storage exists:
#   bash 11-create-core-lxcs.sh all           # everything
#   bash 11-create-core-lxcs.sh adguard       # just one
#   bash 11-create-core-lxcs.sh all --ha      # also enroll each in HA
#
# Containers are unprivileged Debian 13, rootfs on Ceph, provisioned by the
# matching scripts/core/provision-<name>.sh pushed into the container.

source "$(dirname "$0")/lib.sh"
require_root
require_pve

TARGET="${1:-}"
HA_FLAG="${2:-}"
[[ -n "$TARGET" ]] || die "usage: $0 all|adguard|caddy|wireguard|kuma|adguard2 [--ha]"
[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet — LXC rootfs lives on ${VM_POOL}"

# ── Debian 13 container template ──────────────────────────────────────────
log "Ensuring Debian 13 LXC template is available"
pveam update >/dev/null
TMPL="$(pveam available --section system | awk '/debian-13-standard/{print $2}' | sort -V | tail -1)"
[[ -n "$TMPL" ]] || die "no debian-13-standard template found in 'pveam available'"
pveam list local | grep -q "$TMPL" || pveam download local "$TMPL"

# ── SSH key (same logic as the VM script) ─────────────────────────────────
KEYFILE=""
for k in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [[ -f "$k" ]] && { KEYFILE="$k"; break; }
done
if [[ -z "$KEYFILE" ]]; then
    ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
    KEYFILE=/root/.ssh/id_ed25519.pub
fi

# Render a provision asset: substitute @TOKENS@ from cluster.env values
render() { # render <src> <dst>
    sed -e "s|@DOMAIN@|${DOMAIN}|g" \
        -e "s|@SERVARR_IP@|${SERVARR_IP}|g" \
        -e "s|@CLOUDDATA_IP@|${CLOUDDATA_IP}|g" \
        -e "s|@CLOUD1_IP@|${CLOUD_APP_IPS[0]}|g" \
        -e "s|@CLOUD2_IP@|${CLOUD_APP_IPS[1]}|g" \
        -e "s|@HAOS_IP@|${HAOS_IP}|g" \
        -e "s|@ADGUARD_IP@|${CORE_LXC_IPS[0]}|g" \
        -e "s|@ADGUARD2_IP@|${CORE_LXC_IPS[4]}|g" \
        -e "s|@CADDY_IP@|${CORE_LXC_IPS[1]}|g" \
        -e "s|@WIREGUARD_IP@|${CORE_LXC_IPS[2]}|g" \
        -e "s|@KUMA_IP@|${CORE_LXC_IPS[3]}|g" \
        -e "s|@NODE1_IP@|${NODE_IPS[0]}|g" \
        -e "s|@WG_ENDPOINT@|${WG_ENDPOINT}|g" \
        -e "s|@WG_SUBNET@|${WG_SUBNET}|g" \
        "$1" > "$2"
}

create_one() {
    local name="$1" i id ip
    for i in "${!CORE_LXC_NAMES[@]}"; do
        [[ "${CORE_LXC_NAMES[$i]}" == "$name" ]] && break
    done
    [[ "${CORE_LXC_NAMES[$i]}" == "$name" ]] || die "unknown service '$name'"
    id="${CORE_LXC_IDS[$i]}" ip="${CORE_LXC_IPS[$i]}"

    if pct status "$id" >/dev/null 2>&1; then
        log "$name: container $id already exists — skipping create"
    else
        log "$name: creating LXC $id (${CORE_LXC_CORES[$i]} cores, ${CORE_LXC_MEM[$i]} MB, ${ip})"
        pct create "$id" "local:vztmpl/${TMPL}" \
            --hostname "$name" \
            --unprivileged 1 \
            --features nesting=1 \
            --ostype debian \
            --cores "${CORE_LXC_CORES[$i]}" \
            --memory "${CORE_LXC_MEM[$i]}" \
            --swap 0 \
            --rootfs "${VM_POOL}:${CORE_LXC_DISK_GB}" \
            --net0 "name=eth0,bridge=vmbr0,ip=${ip}/24,gw=${LAN_GATEWAY}" \
            --nameserver "${LAN_DNS}" \
            --ssh-public-keys "$KEYFILE" \
            --onboot 1
    fi

    pct status "$id" | grep -q running || pct start "$id"

    log "$name: waiting for network inside the container"
    pct exec "$id" -- bash -c \
        'for i in $(seq 1 30); do getent hosts deb.debian.org >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1' \
        || die "$name: no network/DNS inside container $id"

    log "$name: provisioning (this can take a few minutes)"
    local tmp prov; tmp="$(mktemp -d)"
    prov="$(echo "$name" | sed 's/[0-9]*$//')"   # adguard2 → provision-adguard.sh
    render "${SCRIPT_DIR}/core/provision-${prov}.sh" "${tmp}/provision.sh"
    pct push "$id" "${tmp}/provision.sh" /root/provision.sh
    # extra assets, service-specific
    case "$name" in
    caddy)
        render "${SCRIPT_DIR}/core/Caddyfile"  "${tmp}/Caddyfile"
        render "${SCRIPT_DIR}/core/index.html" "${tmp}/index.html"
        pct push "$id" "${tmp}/Caddyfile"  /root/Caddyfile
        pct push "$id" "${tmp}/index.html" /root/index.html
        ;;
    wireguard)
        render "${SCRIPT_DIR}/core/wg-add-peer" "${tmp}/wg-add-peer"
        pct push "$id" "${tmp}/wg-add-peer" /root/wg-add-peer
        ;;
    esac
    rm -rf "$tmp"
    pct exec "$id" -- bash /root/provision.sh

    if [[ "$HA_FLAG" == "--ha" ]]; then
        ha-manager add "ct:${id}" --state started 2>/dev/null \
            && log "$name: enrolled in HA" \
            || log "$name: already in HA"
    fi
    log "$name: done → http://${ip}"
}

if [[ "$TARGET" == "all" ]]; then
    for n in "${CORE_LXC_NAMES[@]}"; do create_one "$n"; done
else
    create_one "$TARGET"
fi

echo
log "Core services created. Post-install checklist: docs/09-core-services.md"
echo "  - AdGuard first-run wizard:  http://${CORE_LXC_IPS[0]}:3000"
echo "  - Portal (via Caddy):        http://${CORE_LXC_IPS[1]}"
echo "  - Add a WireGuard client:    pct exec ${CORE_LXC_IDS[2]} -- wg-add-peer <name>"
echo "  - Uptime Kuma:               http://${CORE_LXC_IPS[3]}:3001"
