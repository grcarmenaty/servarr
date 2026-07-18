#!/usr/bin/env bash
# Enroll EVERY guest defined in cluster.env into Proxmox HA, and keep the
# redundant pairs (cloud1/cloud2, adguard/adguard2) on different nodes with
# anti-affinity rules. Idempotent — run any time, from any node.
#
#   bash 20-enable-ha.sh

source "$(dirname "$0")/lib.sh"
require_root
require_pve

pvecm status >/dev/null 2>&1 || die "no cluster — HA needs the 3-node cluster up"

enroll() { # enroll vm:<id>|ct:<id> <label>
    local sid="$1" label="$2" id="${1#*:}"
    case "$sid" in
        vm:*) qm status "$id"  >/dev/null 2>&1 || { log "${label}: VM ${id} doesn't exist yet — skipping"; return; } ;;
        ct:*) pct status "$id" >/dev/null 2>&1 || { log "${label}: CT ${id} doesn't exist yet — skipping"; return; } ;;
    esac
    if ha-manager status | grep -q "service ${sid} "; then
        log "${label}: already HA-managed"
    else
        ha-manager add "$sid" --state started
        log "${label}: enrolled in HA"
    fi
}

log "Enrolling all guests"
for i in "${!CORE_LXC_NAMES[@]}"; do
    enroll "ct:${CORE_LXC_IDS[$i]}" "${CORE_LXC_NAMES[$i]}"
done
enroll "vm:${SERVARR_VMID}"   "${SERVARR_NAME}"
enroll "vm:${HAOS_VMID}"      "haos"
enroll "vm:${CLOUDDATA_VMID}" "${CLOUDDATA_NAME}"
for i in "${!CLOUD_APP_VMIDS[@]}"; do
    enroll "vm:${CLOUD_APP_VMIDS[$i]}" "${CLOUD_APP_NAMES[$i]}"
done
enroll "vm:${PHOTOS_VMID}" "${PHOTOS_NAME}"

# Wazuh: heavy + self-restarts fine → HA opt-in via cluster.env (docs/06)
if [[ "${HA_ENROLL_WAZUH:-no}" == "yes" ]]; then
    enroll "vm:${WAZUH_VMID}" "${WAZUH_NAME}"
else
    log "${WAZUH_NAME}: HA_ENROLL_WAZUH=no — left un-HA to fit the RAM budget (docs/06)"
fi

# AI VM: skip if GPU-pinned; otherwise HA opt-in via cluster.env
if qm config "${AI_VMID}" 2>/dev/null | grep -q '^hostpci'; then
    log "${AI_NAME}: GPU passthrough detected — node-pinned, skipping HA (docs/16)"
elif [[ "${HA_ENROLL_AI:-no}" == "yes" ]]; then
    enroll "vm:${AI_VMID}" "${AI_NAME}"
else
    log "${AI_NAME}: HA_ENROLL_AI=no — left un-HA to fit the RAM budget (docs/06)"
fi
# NOT enrolled on purpose: desktop/GPU VMs from scripts/30 (docs/15).

# ── anti-affinity: redundant pairs must not share a node ──────────────────
# PVE 9 HA resource-affinity rules; falls back to a GUI hint on older CLIs.
add_apart_rule() { # add_apart_rule <rule-name> <sid1> <sid2>
    local rule="$1" a="$2" b="$3"
    if ha-manager rules list 2>/dev/null | grep -q "$rule"; then
        log "rule '${rule}': already present"
        return
    fi
    if ha-manager rules add resource-affinity "$rule" \
            --resources "$a,$b" --affinity negative 2>/dev/null; then
        log "rule '${rule}': ${a} and ${b} will run on different nodes"
    else
        warn "could not add rule '${rule}' via CLI (needs PVE 9 HA affinity rules)."
        warn "Set it in the GUI instead: Datacenter → HA → Affinity Rules →"
        warn "  Add: Resource Affinity, resources ${a} + ${b}, 'Keep Separate'."
    fi
}

add_apart_rule "nextcloud-apart" "vm:${CLOUD_APP_VMIDS[0]}" "vm:${CLOUD_APP_VMIDS[1]}"
add_apart_rule "dns-apart"       "ct:${CORE_LXC_IDS[0]}"    "ct:${CORE_LXC_IDS[4]}"

echo
ha-manager status
echo
log "HA policy applied. Test it someday: hard-reset one node and watch"
log "Datacenter → HA — everything should be back within ~3 minutes,"
log "and Nextcloud + DNS shouldn't blip at all."
