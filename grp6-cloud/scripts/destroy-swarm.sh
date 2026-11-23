#!/usr/bin/env bash
# Usage: ./destroy-swarm.sh <cluster-name> [--yes]
set -euo pipefail

CLUSTER="${1:-}"; FORCE="${2:-}"
TF_DIR="$HOME/grp6-cloud/terraform/iaas"
[ -n "$CLUSTER" ] || { echo "Usage: $0 <cluster-name> [--yes]"; exit 1; }

if [ -z "${TF_VAR_pm_token:-}" ]; then
  read -s -p "Proxmox token: " TF_VAR_pm_token; echo
  export TF_VAR_pm_token
fi

cd "$TF_DIR"
mapfile -t WSS < <(terraform workspace list | sed 's/^[* ]*//' | grep -E "^vm-${CLUSTER}-[0-9]+$" || true)
[ "${#WSS[@]}" -gt 0 ] || { echo "No workspaces found for cluster $CLUSTER"; exit 1; }

echo "This will destroy these VMs:"
for WS in "${WSS[@]}"; do echo "  ${WS#vm-}"; done
if [ "$FORCE" != "--yes" ]; then
  read -p "Type the cluster name to confirm: " C
  [ "$C" = "$CLUSTER" ] || { echo "Cancelled"; exit 1; }
fi

for WS in "${WSS[@]}"; do
  NAME="${WS#vm-}"
  terraform workspace select "$WS" >/dev/null
  if [ -n "$(terraform state list 2>/dev/null)" ]; then
    terraform destroy -auto-approve -var "name=$NAME"
  fi
  terraform workspace select default >/dev/null
  terraform workspace delete "$WS" >/dev/null
  echo "Destroyed $NAME"
done
echo "Cluster $CLUSTER removed"

