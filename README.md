# Cloud hybride – Groupe 6 (RCN)

Maquette d'un **cloud hybride** réalisée pour l'étude de cas « Crédit bancaire / BITS ».

Le cloud privé tourne sur **Proxmox VE**, le cloud public sur **Microsoft Azure**. Les deux sont pilotés depuis un **portail self-service unique (Semaphore)**, avec **Terraform** pour le provisionnement et **Ansible** pour la configuration. La supervision est assurée par **Prometheus et Grafana**.

> Objectif métier : ramener la mise à disposition d'une VM de **3 semaines (40 jours-homme)** à **quelques minutes**, avec libre-service, élasticité et consommation mesurée.

**Équipe** : Yorgo Younes · Ali El Boukili · Maxime Chen · Soufian Aboulhana

---

## Sommaire

1. [Architecture](#1-architecture)
2. [Plan d'adressage](#2-plan-dadressage)
3. [Organisation du dépôt](#3-organisation-du-dépôt)
4. [Catalogue de services](#4-catalogue-de-services)
5. [Utiliser le portail Semaphore](#5-utiliser-le-portail-semaphore)
6. [Utilisation en ligne de commande](#6-utilisation-en-ligne-de-commande)
7. [Configuration de Semaphore](#7-configuration-de-semaphore)
8. [Azure : contraintes de l'abonnement étudiant](#8-azure--contraintes-de-labonnement-étudiant)
9. [Supervision](#9-supervision)
10. [Accès à distance](#10-accès-à-distance)
11. [Sécurité](#11-sécurité)
12. [Sauvegarde](#12-sauvegarde)
13. [Dépannage](#13-dépannage)
14. [Limites et travaux restants](#14-limites-et-travaux-restants)

---

## 1. Architecture

```
                         ┌──────────────────────────── Utilisateurs ───────────────────────────┐
                         │      Navigateur → Semaphore (http://172.16.117.102:3000)            │
                         └──────────────────────────────────┬──────────────────────────────────┘
                                                            │
                     ┌──────────────────── admin-fabric (VM 100) ───────────────────┐
                     │  Semaphore (portail + orchestration)                          │
                     │  Ansible (configuration) · Terraform (provisionnement)        │
                     └───────────────┬───────────────────────────────┬──────────────┘
                                     │ API Proxmox                   │ API Azure (az CLI)
          ┌──────────── CLOUD PRIVÉ : pve1 (Proxmox VE 9) ───────┐   │
          │  ZFS rpool → stockage local-zfs                      │   │   ┌──── CLOUD PUBLIC : Azure ────┐
          │  vmbr0 : réseau école 172.16.117.0/24                │   └──▶│  spaincentral                 │
          │  vmbr1 : réseau interne 10.6.0.0/24 (NAT)            │       │  VM Linux (IaaS)              │
          │  Templates : 9000 Ubuntu 24.04 · 9100 Win 2019       │       │  AKS + nginx + HPA (CaaS)     │
          │  VM : admin-fabric, mon1, VM du portail…             │       └───────────────┬───────────────┘
          └──────────────────────────┬───────────────────────────┘                       │
                                     │                                                    │
                         ┌───────── mon1 (VM 101) ─────────┐                              │
                         │ Prometheus · Grafana · pve-exp. │◀──── node_exporter :9100 ────┘
                         └─────────────────────────────────┘
```

| Couche (cours « Fabric MGMT ») | Outil |
|---|---|
| Pool de ressources | Proxmox VE (KVM) + ZFS ; Azure |
| Automatisation et déploiement | Terraform (`bpg/proxmox`, `azurerm`, `kubernetes`) |
| Configuration | Ansible |
| Orchestration et portail | Semaphore UI |
| Supervision (« service mesuré ») | Prometheus + Grafana |

| Machine | Rôle | Accès |
|---|---|---|
| **pve1** | Hyperviseur Proxmox VE 9 (16 cœurs, 39 Go de RAM), ZFS, connecteur VPN CloudConnexa | 172.16.117.100 · iLO 172.16.112.21 |
| **pve2** | 2ᵉ hyperviseur, installé en ZFS : **sans lien réseau** (baie 12 du châssis) | 172.16.117.101 · iLO 172.16.112.22 |
| **admin-fabric** (VM 100) | Terraform, Ansible, Semaphore, Azure CLI | 10.6.0.10 · 172.16.117.102 |
| **mon1** (VM 101) | Prometheus, Grafana, exporteur Proxmox (Docker Compose) | 10.6.0.50 |
| **tpl-ubuntu-2404** (9000) | Template Linux (image cloud + cloud-init) | — |
| **tpl-win2019** (9100) | Template Windows Server 2019 (VirtIO + cloudbase-init + sysprep) | — |

---

## 2. Plan d'adressage

### Réseau de l'école (`vmbr0`), plage du groupe : 172.16.117.100 – 119

| IP | Usage |
|---|---|
| 172.16.117.1 | Passerelle |
| .100 | pve1 |
| .101 | pve2 |
| .102 | admin-fabric (2ᵉ carte) : portail Semaphore |
| .103 – .119 | Réservées (Grafana, services exposés…) |

### Réseau interne (`vmbr1`) : 10.6.0.0/24, NAT vers `vmbr0`

| IP | Usage |
|---|---|
| 10.6.0.1 | pve1 (passerelle des VM) |
| 10.6.0.10 | admin-fabric |
| 10.6.0.50 | mon1 |
| 10.6.0.100 – .199 | VM créées depuis le portail (IaaS, Docker, Swarm, DBaaS) |

> Avant de choisir une IP, vérifiez qu'elle est libre : `ping -c 2 <IP>` ne doit pas répondre. Les scripts refusent de toute façon une IP qui répond déjà.

---

## 3. Organisation du dépôt

Emplacement : `/home/grp6/grp6-cloud` sur **admin-fabric**.

```
grp6-cloud/
├── terraform/
│   ├── iaas/            # Module Proxmox : clone d'un template (Linux/Windows, S/M/L)
│   │   ├── main.tf
│   │   └── grp6_keys.pub   # Clés SSH publiques autorisées dans les VM Linux
│   ├── azure-vm/        # VM Linux Azure (IaaS public)
│   │   └── main.tf
│   └── azure-aks/       # Cluster AKS + nginx + HPA + LoadBalancer
│       └── main.tf
├── playbooks/           # Playbooks lancés par les boutons Semaphore
│   ├── iaas_create_vm.yml      iaas_delete_vm.yml
│   ├── docker_create.yml       docker_delete.yml
│   ├── swarm_create.yml        swarm_delete.yml
│   ├── db_create.yml
│   ├── azure_vm_create.yml     azure_vm_delete.yml
│   └── azure_aks_create.yml    azure_aks_delete.yml
├── scripts/             # Scripts de déploiement (Terraform + Ansible)
│   ├── deploy-docker.sh   destroy-docker.sh
│   ├── deploy-swarm.sh    destroy-swarm.sh
│   └── deploy-db.sh
└── ansible/             # Rôles de configuration appelés par les scripts
    ├── ansible.cfg  inventory.ini
    ├── docker.yml   db.yml
    └── swarm.yml    swarm-auto.yml
```

**État Terraform** : stocké **hors du dépôt**, dans `/home/grp6/tfstate/` :

| Dossier | Contenu |
|---|---|
| `tfstate/iaas/` | Un workspace par VM Proxmox : `vm-<nom>` |
| `tfstate/azure-vm/` | État de la VM Azure |
| `tfstate/azure-aks/` | État du cluster AKS |

> ⚠️ Ne mettez jamais dans le dépôt les fichiers `terraform.tfvars`, `*.tfstate*` ou `.terraform/`, ni aucun secret.

---

## 4. Catalogue de services

### Gabarits de VM (cloud privé)

Les tailles correspondent aux configurations les plus fréquentes du parc existant de BITS (2 vCPU / 4 Go est la plus répandue).

| Taille | vCPU | RAM |
|---|---|---|
| `small` | 1 | 2 Go |
| `medium` | 2 | 4 Go |
| `large` | 4 | 8 Go |

### Services disponibles

| Cloud | Service | Modèle | Bouton Semaphore | Mise en œuvre |
|---|---|---|---|---|
| Privé | VM Linux / Windows | IaaS | Privé – Créer / Supprimer une VM | Terraform clone le template 9000 ou 9100 |
| Privé | Hôte Docker | CaaS | Privé – Créer / Supprimer un hôte Docker | `deploy-docker.sh` → Terraform + `docker.yml` |
| Privé | Cluster Docker Swarm | CaaS | Privé – Créer / Supprimer un cluster Docker Swarm | `deploy-swarm.sh` → 3 VM + `swarm-auto.yml` |
| Privé | Base MariaDB | DBaaS | Privé – Créer une base de données (DBaaS) | `deploy-db.sh` → Terraform + `db.yml` |
| Public | VM Linux Azure | IaaS | Public – Créer / Supprimer la VM Azure | Terraform `azurerm` |
| Public | Cluster Kubernetes AKS | CaaS | Public – Créer / Supprimer le cluster Kubernetes | Terraform `azurerm` + `kubernetes` (HPA 3 à 6 réplicas) |

---

## 5. Utiliser le portail Semaphore

1. Ouvrez **http://172.16.117.102:3000** (depuis l'école, ou chez vous via le VPN).
2. Projet **Cloud hybride grp6** → **Task Templates** (onglets **Privé** et **Public**).
3. Cliquez sur ▶ à côté du service voulu, remplissez le formulaire, puis **Run**.
4. Suivez le log : un run réussi se termine par `failed=0`.

### Champs des formulaires

| Bouton | Champs |
|---|---|
| Créer une VM | `vm_name`, `vm_size` (small/medium/large), `vm_ip` (10.6.0.100–199), `vm_os` (linux/windows), `vm_password` (Windows uniquement) |
| Supprimer une VM | `vm_name`, `vm_ip` (les mêmes valeurs qu'à la création) |
| Créer un hôte Docker | `vm_name`, `vm_size`, `vm_ip` |
| Créer un cluster Swarm | `swarm_name`, `swarm_size`, `swarm_ip` (1ʳᵉ IP ; les suivantes sont consécutives), `swarm_count` (facultatif, 3 par défaut) |
| Créer une base (DBaaS) | `vm_name`, `vm_size`, `vm_ip`, `db_name`, `db_user`, `db_root_password`, `db_password` |
| Boutons Azure | Aucun champ |

> Une VM de base de données se supprime avec le bouton **Supprimer un hôte Docker** (même type de VM).
> Ne supprimez **jamais** `mon1` ni `admin-fabric` depuis le portail.

### Connexion aux VM créées

```bash
# Linux : depuis admin-fabric (clé SSH injectée par cloud-init)
ssh grp6@10.6.0.1xx

# Windows : bureau à distance via un tunnel par pve1 (depuis votre PC)
ssh -L 3389:10.6.0.1xx:3389 root@172.16.117.100
# puis un client RDP sur localhost, utilisateur Administrator
```

---

## 6. Utilisation en ligne de commande

Toutes les commandes se lancent sur **admin-fabric**, en tant que `grp6`.

### Prérequis de session

```bash
export TF_VAR_pm_token='terraform@pve!tf=<secret>'        # token API Proxmox
az account show -o table                                   # session Azure active
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

### Cloud privé

```bash
cd ~/grp6-cloud/scripts
./deploy-docker.sh docker01 small 10.6.0.130
./deploy-swarm.sh  swarm    small 10.6.0.120 3
./deploy-db.sh     db01     small 10.6.0.131 crm crmuser      # mots de passe demandés
./destroy-swarm.sh swarm --yes
./destroy-docker.sh docker01 --yes
```

VM seule (Linux ou Windows) :

```bash
cd ~/grp6-cloud/terraform/iaas
terraform workspace select -or-create vm-web01
terraform apply -var=name=web01 -var=size=medium -var=ip=10.6.0.101 -var=os=linux
terraform destroy -var=name=web01 -var=ip=10.6.0.101
terraform workspace select default && terraform workspace delete vm-web01
```

Pour une VM Windows, ajoutez `-var=os=windows` et exportez `TF_VAR_admin_password`.

### Démo « scale-up à trois fronts » (Docker Swarm)

```bash
ssh grp6@10.6.0.120 docker service create --name web --replicas 1 -p 80:80 nginx
ssh grp6@10.6.0.120 docker service scale web=3
ssh grp6@10.6.0.120 docker service ps web
curl -s http://10.6.0.122 | grep -i title     # le routing mesh répond sur tous les nœuds
```

### Cloud public (Azure)

```bash
# VM Linux
cd ~/grp6-cloud/terraform/azure-vm
terraform init && terraform apply
$(terraform output -raw ssh_command) hostname
terraform destroy

# AKS (en deux temps)
cd ~/grp6-cloud/terraform/azure-aks
terraform init
terraform apply -target=azurerm_kubernetes_cluster.aks
az aks get-credentials -g rg-grp6-aks -n aks-grp6 --overwrite-existing
terraform apply
curl -s $(terraform output -raw web_url) | grep -i title
terraform destroy
```

### Démo d'autoscaling AKS (HPA)

```bash
watch -n 2 kubectl get hpa,pods                      # terminal 1
for i in 1 2 3 4 5 6; do                             # terminal 2
  kubectl run load-$i --image=busybox --restart=Never -- \
    /bin/sh -c "while true; do wget -q -O- http://web-front >/dev/null; done"
done
kubectl delete pod load-1 load-2 load-3 load-4 load-5 load-6
```

Quand le CPU dépasse 50 %, les réplicas passent de 3 à 6, puis redescendent à 3 environ 5 minutes après l'arrêt de la charge.

---

## 7. Configuration de Semaphore

Semaphore tourne en natif sur admin-fabric (service `semaphore`, base SQLite, utilisateur `grp6`), donc il utilise directement Terraform, Ansible, la clé SSH et la session Azure de `grp6`.

| Élément | Valeur |
|---|---|
| Key Store | `none` (type None) |
| Repository | `grp6-cloud` → `/home/grp6/grp6-cloud` |
| Inventory | `localhost`, statique : `localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3` |
| Variable Group `proxmox` | Secret : `TF_VAR_pm_token` |
| Variable Group `azure` | `ARM_SUBSCRIPTION_ID`, `TF_VAR_my_ip=81.250.245.205`, `TF_VAR_location=spaincentral`, `TF_VAR_vm_size=Standard_D2s_v4` |

```bash
sudo systemctl status semaphore      # état du service
sudo systemctl restart semaphore     # redémarrage
```

---

## 8. Azure : contraintes de l'abonnement étudiant

| Contrainte | Valeur constatée |
|---|---|
| Régions autorisées | spaincentral, francecentral, polandcentral, germanywestcentral, denmarkeast |
| Région utilisée | **spaincentral** : la seule qui autorise des tailles de VM utiles |
| Taille utilisée | **Standard_D2s_v4** (2 vCPU / 8 Go) : la famille B est bloquée partout |
| Quotas | 6 vCPU au total dans la région, **4 vCPU pour la famille DSv4** (VM + 1 nœud AKS) |
| Authentification | Session `az` de l'utilisateur : le tenant aforp.eu bloque la connexion par code (`--use-device-code`) et la création de service principals |
| Fournisseurs enregistrés | Microsoft.Network, Compute, ContainerService, ManagedIdentity, ContainerInstance, Sql, Web, Storage |
| Coût indicatif | ≈ 0,10 €/h par VM ou nœud D2s_v4 → **toujours supprimer après les tests** |

Versions testées : Terraform 1.17, azurerm 5.14.0, kubernetes 2.38.0, bpg/proxmox.

> La session Azure peut expirer : vérifiez `az account show` avant chaque démo.

---

## 9. Supervision

Installée sur **mon1**, dans `~/monitoring`, avec Docker Compose :

| Composant | Rôle | Port |
|---|---|---|
| prometheus-pve-exporter | Métriques Proxmox (nœud, VM, stockage) par l'API (token en lecture seule `monitor@pve!prom`) | 9221 (interne) |
| Prometheus | Collecte toutes les 15 s : jobs `pve` et `azure-vm` | 9090 |
| Grafana | Tableaux de bord | 3000 |

- La VM Azure installe **node_exporter** automatiquement au démarrage (cloud-init). Le port 9100 n'est ouvert qu'à l'IP de l'école.
- La cible Azure est déclarée dans `~/monitoring/targets/azure.yml`. **À mettre à jour à chaque recréation de la VM**, car son IP publique change. Prometheus relit le fichier tout seul.
- Tableaux de bord : **10347** (Proxmox), **1860** (Node Exporter Full), plus le tableau de bord maison « Cloud hybride grp6 ».

```bash
cd ~/monitoring
docker compose up -d
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

---

## 10. Accès à distance

Depuis l'extérieur, l'accès passe par le **VPN CloudConnexa**. Son connecteur tourne sur pve1, qui relaie le trafic des clients VPN (100.64.0.0/10) vers le réseau de l'école grâce à un NAT.

| Service | Adresse |
|---|---|
| Proxmox | https://172.16.117.100:8006 |
| Semaphore | http://172.16.117.102:3000 |
| admin-fabric (SSH) | `ssh grp6@172.16.117.102` |
| Prometheus / Grafana | `ssh -L 9090:10.6.0.50:9090 -L 3001:10.6.0.50:3000 root@172.16.117.100` → http://localhost:9090 et http://localhost:3001 |
| VM internes (SSH) | `ssh -J root@172.16.117.100 grp6@10.6.0.x` |

> Après la suppression puis la recréation d'une VM sur la même IP : `ssh-keygen -R <IP>`.

---

## 11. Sécurité

- Accès aux VM Linux **par clé SSH uniquement** ; aucun mot de passe dans le code.
- Secrets (token Proxmox, mots de passe des bases et de Windows) passés par **variables d'environnement** ou secrets Semaphore, jamais en ligne de commande ni dans les fichiers versionnés.
- Pare-feu Azure (NSG) : SSH et node_exporter **limités à l'IP publique de l'école**.
- Comptes de service dédiés : `terraform@pve` (provisionnement), `monitor@pve` (lecture seule).
- Un compte Semaphore par membre : chaque demande est tracée.

**Pour la production** (hors maquette) :

- HTTPS devant Semaphore et Grafana ;
- authentification centralisée (AD/LDAP) ;
- coffre-fort de secrets (Vault) ;
- service principal Azure limité au groupe de ressources ;
- état Terraform distant et verrouillé (Azure Storage) ;
- rôle Proxmox au moindre privilège à la place de `PVEAdmin`.

---

## 12. Sauvegarde

Tout le code et l'état Terraform vivent sur **admin-fabric**. Sauvegardez-la régulièrement, et **avant chaque démo** :

```bash
# Sur pve1
vzdump 100 --storage local --mode snapshot --compress zstd
vzdump 101 --storage local --mode snapshot --compress zstd     # mon1
```

Copie du code sur un PC :

```bash
scp -r -J root@172.16.117.100 grp6@10.6.0.10:~/grp6-cloud ./grp6-cloud-backup
```

---

## 13. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `Currently selected workspace "X" does not exist` | Mémoire du workspace de Terraform | Supprimer `terraform/iaas/.terraform/environment`, puis relancer |
| `the API token must be in the format 'USER@REALM!TOKENID=UUID'` | Valeur de `TF_VAR_pm_token` incorrecte | Format exact `terraform@pve!tf=<uuid>`, sans guillemets ni espace |
| `storage 'local-lvm' does not exist` | Stockage par défaut du provider | `datastore_id = "local-zfs"` dans le bloc `initialization` |
| `playbook … could not be found` | Espace ou tabulation invisible dans le champ Playbook de Semaphore | Retaper le chemin à la main |
| `MissingSubscriptionRegistration` | Fournisseur Azure non enregistré | `az provider register --namespace <Fournisseur> --wait` |
| `SkuNotAvailable` | Taille ou région bloquée par l'abonnement | Rester sur `spaincentral` + `Standard_D2s_v4` |
| `Insufficient node_provisioning_profile blocks` | Bloc obligatoire avec azurerm 5.x | `node_provisioning_profile { mode = "Manual" }` |
| `terraform plan` AKS jamais à « No changes » | Valeur posée par Azure | Déclarer `upgrade_settings { max_surge = "10%" }` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | VM recréée avec la même IP | `ssh-keygen -R <IP>` |
| Clone Windows sans nom ni IP | cloudbase-init | Journal : `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log` |
| Accès aux iLO perdu via VPN après un reboot de pve1 | Règle NAT 100.64.0.0/10 non persistante | Recréer la règle `iptables` (ou activer le service `vpn-nat`) |

---

## 14. Limites et travaux restants

| Élément | État |
|---|---|
| Cluster Proxmox à 2 nœuds (migration, HA, réplication ZFS) | ⏳ Bloqué : pve2 sans lien réseau (profil Virtual Connect de la baie 12). Plan B : cluster imbriqué sur pve1 |
| Active Directory (authentification centralisée) | ⏳ À faire |
| Stockage partagé : LUN iSCSI présentée aux nœuds | ⏳ À faire |
| SaaS (WordPress + MySQL sur Swarm) | ⏳ À faire |
| Big Data (cluster Hadoop) | ⏳ À faire |
| Azure : conteneurs (ACI), Azure SQL, Web App | ⏳ À faire |
| Portail ITSM (GLPI) en façade de Semaphore | Architecture cible, hors maquette |
| Licences Windows | Évaluation 180 jours (production : Windows Server Datacenter par hôte) |
| Mises à jour Windows dans le template | Non appliquées (maquette) |
