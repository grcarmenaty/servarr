#!/usr/bin/env bash
# Repo self-check: run before committing or building. Validates shell
# syntax, compose YAML, that every @TOKEN@ used in core assets is
# substituted by 11-create-core-lxcs.sh, and that static IPs don't collide.
# Pure checks — reads the repo, changes nothing. Run from anywhere.
#
#   bash scripts/validate-repo.sh
#
# Exit non-zero on any failure (usable as a Forgejo Actions / pre-commit gate).

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
red() { echo -e "\e[1;31m$*\e[0m"; }
grn() { echo -e "\e[1;32m$*\e[0m"; }

echo "== shell syntax =="
while IFS= read -r -d '' f; do
    bash -n "$f" || { red "  syntax: $f"; fail=1; }
done < <(find . -name '*.sh' -not -path './.git/*' -print0)
[[ $fail -eq 0 ]] && grn "  ok" || true

echo "== compose YAML =="
if command -v python3 >/dev/null; then
    python3 - <<'PY' || fail=1
import glob, sys
try:
    import yaml
except ImportError:
    print("  (pyyaml absent — skipping)"); sys.exit(0)
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda l,s,n: None)
bad=0
for f in sorted(glob.glob('**/*.yml', recursive=True)):
    if '/.git/' in f: continue
    try: list(yaml.load_all(open(f), Loader=L))
    except Exception as e: print(f"  YAML: {f}: {e}"); bad=1
print("  ok" if not bad else "  FAILED"); sys.exit(bad)
PY
else
    echo "  (python3 absent — skipping)"
fi

echo "== token substitution (core assets) =="
# every @TOKEN@ used in scripts/core/ must be substituted by SOME script
# (11-create-core-lxcs.sh for the LXC assets, 17-create-ai-lxc.sh for @GPU@)
mapfile -t used < <(grep -ohrE '@[A-Z0-9_]+@' scripts/core/ 2>/dev/null | grep -v '@TOKENS@' | sort -u)
subs="$(grep -ohE 's\|@[A-Z0-9_]+@\|' scripts/*.sh | sort -u)"
missing=0
for t in "${used[@]}"; do
    grep -qF "s|${t}|" <<<"$subs" || { red "  not substituted by any script: $t"; missing=1; fail=1; }
done
[[ $missing -eq 0 ]] && grn "  ok" || true

echo "== static IP collisions (cluster.env) =="
# AI_LXC_IP intentionally equals AI_IP (VM or LXC, never both — docs/16),
# so exclude that one line from the dup check.
dupes="$(grep -E '^[A-Z].*=.*10\.0\.0\.[0-9]+' scripts/cluster.env \
    | grep -v '^AI_LXC_IP=' \
    | grep -oE '10\.0\.0\.[0-9]+' | grep -v '10.0.0.254' | sort | uniq -d)"
if [[ -n "$dupes" ]]; then red "  duplicate IPs: $dupes"; fail=1; else grn "  ok"; fi

echo
[[ $fail -eq 0 ]] && grn "ALL CHECKS PASSED" || { red "CHECKS FAILED"; exit 1; }
