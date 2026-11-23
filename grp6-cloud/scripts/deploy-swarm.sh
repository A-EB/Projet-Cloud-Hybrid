#!/usr/bin/env bash
# Usage: ./deploy-swarm.sh <cluster-name> <small|medium|large> <first-ip> [count=3]
# Creates VMs <cluster-name>-1..N on consecutive IPs. VM 1 = manager, others = workers.
set -euo pipefail

CLUSTER="${1:-}"; SIZE="${2:-}"; FIRST_IP="${3:-}"; COUNT="${4:-3}"
TF_DIR="$HOME/grp6-cloud/terraform/iaas"
ANS_DIR="$HOME/grp6-cloud/ansible"

[[ -n "$CLUSTER" && -n "$SIZE" && -n "$FIRST_IP" ]] || { echo "Usage: $0 <cluster-name> <small|medium|large> <first-ip> [count]"; exit 1; }
[[ "$CLUSTER" =~ ^[a-z0-9-]+$ ]] || { echo "Name: lowercase letters, digits, dashes only"; exit 1; }
[[ "$SIZE" =~ ^(small|medium|large)$ ]] || { echo "Size must be small, medium or large"; exit 1; }
[[ "$FIRST_IP" =~ ^10\.6\.0\.[0-9]{1,3}$ ]] || { echo "IP must be in 10.6.0.x"; exit 1; }
[[ "$COUNT" =~ ^[1-5]$ ]] || { echo "Count must be between 1 and 5"; exit 1; }

BASE="${FIRST_IP%.*}"; LAST="${FIRST_IP##*.}"
(( LAST + COUNT - 1 <= 254 )) || { echo "Not enough addresses after $FIRST_IP"; exit 1; }

# Proxmox token
if [ -z "${TF_VAR_pm_token:-}" ]; then
  read -s -p "Proxmox token: " TF_VAR_pm_token; echo
  export TF_VAR_pm_token
fi

# Refuse if any of the IPs already answers, before creating anything
for i in $(seq 0 $((COUNT-1))); do
  IP="$BASE.$((LAST+i))"
  if ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
    echo "$IP already answers, pick another range"; exit 1
  fi
done

INV=""
trap 'rm -f "$INV"' EXIT
trap 'echo "Failed. To clean up what was created: ./destroy-swarm.sh '"$CLUSTER"'"' ERR

# 1. Terraform: one VM and one workspace per node
cd "$TF_DIR"
for i in $(seq 1 "$COUNT"); do
  NAME="$CLUSTER-$i"; IP="$BASE.$((LAST+i-1))"; WS="vm-$NAME"
  if terraform workspace list | sed 's/^[* ]*//' | grep -qx "$WS"; then
    terraform workspace select "$WS" >/dev/null
  else
    terraform workspace new "$WS" >/dev/null
  fi
  if [ -n "$(terraform state list 2>/dev/null)" ]; then
    echo "Workspace $WS already manages a VM. Stopping so nothing gets modified."
    exit 1
  fi
  echo "=== Creating $NAME ($IP) ==="
  terraform apply -auto-approve -var "name=$NAME" -var "size=$SIZE" -var "ip=$IP"
done
cd "$TF_DIR" && terraform workspace select default >/dev/null
# 2. Wait for SSH and cloud-init on every node
for i in $(seq 1 "$COUNT"); do
  IP="$BASE.$((LAST+i-1))"
  ssh-keygen -R "$IP" >/dev/null 2>&1 || true
  echo "Waiting for SSH on $IP..."
  for t in $(seq 1 40); do
    if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "grp6@$IP" true 2>/dev/null; then
      break
    fi
    if [ "$t" -eq 40 ]; then echo "SSH never answered on $IP"; exit 1; fi
    sleep 5
  done
  ssh -o BatchMode=yes "grp6@$IP" "cloud-init status --wait" >/dev/null 2>&1 || true
done

# 3. Ansible: temporary inventory, node 1 = manager, the rest = workers
INV="$(mktemp)"
{
  echo "[swarm_manager]"
  echo "$CLUSTER-1 ansible_host=$BASE.$LAST"
  echo "[swarm_workers]"
  for i in $(seq 2 "$COUNT"); do
    echo "$CLUSTER-$i ansible_host=$BASE.$((LAST+i-1))"
  done
  echo "[swarm:children]"
  echo "swarm_manager"
  echo "swarm_workers"
} > "$INV"
cd "$ANS_DIR"
ansible-playbook -i "$INV" swarm-auto.yml

# 4. Check
echo "Swarm nodes:"
ssh "grp6@$BASE.$LAST" docker node ls
echo "Done: swarm $CLUSTER, manager $BASE.$LAST, $COUNT nodes"

