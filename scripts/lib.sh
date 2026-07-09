# Shared helpers for the setup scripts. Sourced, not executed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/cluster.env" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/cluster.env not found. Copy the whole scripts/ dir." >&2
    exit 1
fi
# shellcheck source=cluster.env
source "${SCRIPT_DIR}/cluster.env"

log()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33mWARN:\e[0m $*" >&2; }
die()  { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "run as root"
}

require_pve() {
    command -v pveversion >/dev/null 2>&1 || die "this doesn't look like a Proxmox VE node"
}

confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# index of this host in NODE_NAMES, or empty
this_node_index() {
    local host i
    host="$(hostname)"
    for i in "${!NODE_NAMES[@]}"; do
        [[ "${NODE_NAMES[$i]}" == "$host" ]] && { echo "$i"; return; }
    done
}
