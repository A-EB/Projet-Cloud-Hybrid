#!/usr/bin/env bash
# Usage: ./deploy-docker.sh <name> <small|medium|large> <ip>
set -euo pipefail

NAME="${1:-}"; SIZE="${2:-}"; IP="${3:-}"
TF_DIR="$HOME/grp6-cloud/terraform/iaas"
ANS_DIR="$HOME/grp6-cloud/ansible"

[[ -n "$NAME" && -n "$SIZE" && -n "$IP" ]] || { echo "Usage: $0 <name> <small|medium|large> <ip>"; exit 1; }
[[ "$NAME" =~ ^[a-z0-9-]+$ ]] || { echo "Name: lowercase letters, digits, dashes only"; exit 1; }
[[ "$SIZE" =~ ^(small|medium|large)$ ]] || { echo "Size must be small, medium or large"; exit 1; }
[[ "$IP" =~ ^10\.6\.0\.[0-9]{1,3}$ ]] || { echo "IP must be in 10.6.0.x"; exit 1; }

# Token: use the environment variable, or ask silently
if [ -z "${TF_VAR_pm_token:-}" ]; then
  read -s -p "Proxmox token: " TF_VAR_pm_token; echo
  export TF_VAR_pm_token
fi

# Refuse an IP that already answers
if ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
  echo "$IP already answers, pick another IP"; exit 1
fi

# 1. Terraform: one workspace per VM
cd "$TF_DIR"
WS="vm-$NAME"
if terraform workspace list | sed 's/^[* ]*//' | grep -qx "$WS"; then
  terraform workspace select "$WS" >/dev/null
else
  terraform workspace new "$WS" >/dev/null
fi
if [ -n "$(terraform state list)" ]; then
  echo "Workspace $WS already manages a VM. Stopping so nothing gets modified."
  exit 1
fi
terraform apply -auto-approve -var "name=$NAME" -var "size=$SIZE" -var "ip=$IP"

# 2. Wait for SSH and for cloud-init to finish
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
echo "Waiting for SSH on $IP..."
for i in $(seq 1 40); do
  if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "grp6@$IP" true 2>/dev/null; then
    break
  fi
  if [ "$i" -eq 40 ]; then echo "SSH never answered on $IP"; exit 1; fi
  sleep 5
done
ssh -o BatchMode=yes "grp6@$IP" "cloud-init status --wait" >/dev/null 2>&1 || true

# 3. Ansible: temporary inventory with just this VM in the [docker] group
INV="$(mktemp)"
trap 'rm -f "$INV"' EXIT
printf "[docker]\n%s ansible_host=%s\n" "$NAME" "$IP" > "$INV"
cd "$ANS_DIR"
ansible-playbook -i "$INV" docker.yml

echo "Done: $NAME ($IP, $SIZE)"
ssh "grp6@$IP" docker --version
