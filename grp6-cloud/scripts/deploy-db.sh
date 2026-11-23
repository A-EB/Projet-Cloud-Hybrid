#!/usr/bin/env bash
# Usage: ./deploy-db.sh <name> <small|medium|large> <ip> [db_name] [db_user]
# Passwords: DB_ROOT_PASSWORD and DB_PASSWORD (environment), or asked silently
set -euo pipefail

NAME="${1:-}"; SIZE="${2:-}"; IP="${3:-}"
DB_NAME="${4:-appdb}"; DB_USER="${5:-appuser}"
TF_DIR="$HOME/grp6-cloud/terraform/iaas"
ANS_DIR="$HOME/grp6-cloud/ansible"

[[ -n "$NAME" && -n "$SIZE" && -n "$IP" ]] || { echo "Usage: $0 <name> <small|medium|large> <ip> [db_name] [db_user]"; exit 1; }
[[ "$NAME" =~ ^[a-z0-9-]+$ ]] || { echo "Name: lowercase letters, digits, dashes only"; exit 1; }
[[ "$SIZE" =~ ^(small|medium|large)$ ]] || { echo "Size must be small, medium or large"; exit 1; }
[[ "$IP" =~ ^10\.6\.0\.[0-9]{1,3}$ ]] || { echo "IP must be in 10.6.0.x"; exit 1; }
[[ "$DB_NAME" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "db_name: lowercase letters, digits, underscores"; exit 1; }
[[ "$DB_USER" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "db_user: lowercase letters, digits, underscores"; exit 1; }

# Proxmox token
if [ -z "${TF_VAR_pm_token:-}" ]; then
  read -s -p "Proxmox token: " TF_VAR_pm_token; echo
  export TF_VAR_pm_token
fi

# Database passwords
if [ -z "${DB_ROOT_PASSWORD:-}" ]; then
  read -s -p "DB root password: " DB_ROOT_PASSWORD; echo
fi
if [ -z "${DB_PASSWORD:-}" ]; then
  read -s -p "DB user password: " DB_PASSWORD; echo
fi
[ -n "$DB_ROOT_PASSWORD" ] && [ -n "$DB_PASSWORD" ] || { echo "Passwords cannot be empty"; exit 1; }
export DB_ROOT_PASSWORD DB_PASSWORD DB_NAME DB_USER

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
if [ -n "$(terraform state list 2>/dev/null)" ]; then
  echo "Workspace $WS already manages a VM. Stopping so nothing gets modified."
  exit 1
fi
terraform apply -auto-approve -var "name=$NAME" -var "size=$SIZE" -var "ip=$IP"

# 2. Wait for SSH and cloud-init
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

# 3. Ansible: temporary inventory and a private vars file for the passwords
INV=""; VARS=""
trap 'rm -f "$INV" "$VARS"' EXIT
INV="$(mktemp)"; VARS="$(mktemp)"; chmod 600 "$VARS"
printf "[db]\n%s ansible_host=%s\n" "$NAME" "$IP" > "$INV"
python3 -c 'import json,os; e=os.environ; print(json.dumps({"db_root_password":e["DB_ROOT_PASSWORD"],"db_password":e["DB_PASSWORD"],"db_name":e["DB_NAME"],"db_user":e["DB_USER"]}))' > "$VARS"
cd "$ANS_DIR"
ansible-playbook -i "$INV" db.yml -e "@$VARS"

# 4. Check that the user can log in (password sent through stdin, not in the command)
echo "Databases visible to $DB_USER:"
for i in $(seq 1 20); do
  if printf '%s\n' "$DB_PASSWORD" | ssh "grp6@$IP" 'IFS= read -r P; sudo docker exec -e MYSQL_PWD="$P" mariadb mariadb -u '"$DB_USER"' -e "show databases;"' 2>/dev/null; then
    break
  fi
  if [ "$i" -eq 20 ]; then echo "MariaDB never accepted the login"; exit 1; fi
  sleep 3
done
echo "Done: $NAME ($IP, $SIZE), database $DB_NAME, user $DB_USER, port 3306"
