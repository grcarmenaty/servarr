#!/usr/bin/env bash
# Wipe a disk and turn it into a Ceph OSD. Run on the node that owns the disk,
# once per data disk.
#
#   bash 04-create-osds.sh /dev/sdb
#   bash 04-create-osds.sh /dev/sdb /dev/sda4   # optional 2nd arg: SSD DB/WAL device
#
# THE TARGET DISK IS WIPED IRREVERSIBLY. The script shows the disk and asks
# for confirmation first.

source "$(dirname "$0")/lib.sh"
require_root
require_pve

DISK="${1:-}"
DB_DEV="${2:-}"

[[ -n "$DISK" ]] || die "usage: $0 /dev/sdX [db_device]"
[[ -b "$DISK" ]] || die "$DISK is not a block device"
[[ -f /etc/pve/ceph.conf ]] || die "Ceph not initialized — run 03-setup-ceph.sh first"

# refuse the OS disk
ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n1 || true)"
if [[ -n "$ROOT_DISK" && "$DISK" == "/dev/${ROOT_DISK}" ]]; then
    die "$DISK holds the root filesystem — refusing"
fi

# refuse mounted disks
if lsblk -no MOUNTPOINT "$DISK" | grep -q .; then
    lsblk "$DISK"
    die "$DISK has mounted partitions — unmount first if you really mean it"
fi

echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL "$DISK"
echo
confirm "WIPE ${DISK} and create a Ceph OSD on it?" || die "aborted"

log "Zapping ${DISK}"
ceph-volume lvm zap "$DISK" --destroy

OSD_OPTS=()
if [[ "${OSD_ENCRYPT:-no}" == "yes" ]]; then
    OSD_OPTS+=(--encrypted 1)
    log "Creating LUKS-encrypted OSD on ${DISK}"
else
    log "Creating OSD on ${DISK}"
fi
[[ -n "$DB_DEV" ]] && OSD_OPTS+=(--db_dev "$DB_DEV")
pveceph osd create "$DISK" "${OSD_OPTS[@]}"

if [[ -n "${OSD_MEMORY_TARGET}" ]]; then
    log "Setting osd_memory_target=${OSD_MEMORY_TARGET} (cluster-wide)"
    ceph config set osd osd_memory_target "${OSD_MEMORY_TARGET}"
fi

echo
ceph osd tree
