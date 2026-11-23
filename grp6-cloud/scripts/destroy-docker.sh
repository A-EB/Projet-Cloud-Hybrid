#!/usr/bin/env bash
# Usage: ./destroy-docker.sh <name> [--yes]
set -euo pipefail

NAME="${1:-}"; FORCE="${2:-}"
TF_DIR="$HOME/grp6-cloud/terraform/iaas"
[ -n "$NAME" ] || { echo "Usage: $0 <name> [--yes]"; exit 1; }

if [ -z "${TF_VAR_pm_token:-}" ]; then
  read -s -p "Proxmox token: " TF_VAR_pm_token; echo
  export TF_VAR_pm_token
fi

cd "$TF_DIR"
WS="vm-$NAME"
if ! terraform workspace list | sed 's/^[* ]*//' | grep -qx "$WS"; then
  echo "No workspace $WS, nothing to destroy"; exit 1
fi
terraform workspace select "$WS" >/dev/null

if [ -n "$(terraform state list)" ]; then
  echo "This will destroy:"
  terraform state list
  if [ "$FORCE" != "--yes" ]; then
    read -p "Type the VM name to confirm: " C
    [ "$C" = "$NAME" ] || { echo "Cancelled"; exit 1; }
  fi
  terraform destroy -auto-approve -var "name=$NAME"
fi

terraform workspace select default >/dev/null
terraform workspace delete "$WS" >/dev/null
echo "Destroyed $NAME and removed workspace $WS"
