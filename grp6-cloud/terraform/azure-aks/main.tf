terraform {
  backend "local" { path = "/home/grp6/tfstate/azure-aks/terraform.tfstate" }
  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = ">= 4.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.23" }
  }
}

provider "azurerm" {
  features {
    resource_group { prevent_deletion_if_contains_resources = false }
  }
}

# Le provider Kubernetes utilise les certificats du cluster créé ci-dessous
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
}

variable "location"  { default = "spaincentral" }
variable "node_size" { default = "Standard_D2s_v4" }

resource "azurerm_resource_group" "rg" {
  name     = "rg-grp6-aks"
  location = var.location
}

# ---------- Cluster AKS (1 nœud, quota étudiant) ----------
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-grp6"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "grp6-aks"
  sku_tier            = "Free"

  default_node_pool {
    name       = "system"
    node_count = 1
    vm_size    = var.node_size
    
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity { type = "SystemAssigned" }

  node_provisioning_profile {
    mode = "Manual"
  }

  tags = { project = "rcn-grp6", service = "caas-kubernetes" }
}

# ---------- Application : front web nginx ----------
resource "kubernetes_deployment_v1" "web" {
  metadata {
    name   = "web-front"
    labels = { app = "web" }
  }
  spec {
    replicas = 3
    selector { match_labels = { app = "web" } }
    template {
      metadata { labels = { app = "web" } }
      spec {
        container {
          name  = "nginx"
          image = "nginx:stable"
          port { container_port = 80 }
          resources {
            requests = { cpu = "100m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }
      }
    }
  }
  # Le nombre de réplicas est ensuite géré par le HPA, pas par Terraform
  lifecycle { ignore_changes = [spec[0].replicas] }
}

# ---------- Autoscaling horizontal (3 à 6 réplicas) ----------
resource "kubernetes_horizontal_pod_autoscaler_v2" "web" {
  metadata { name = "web-front-hpa" }
  spec {
    min_replicas = 3
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.web.metadata[0].name
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 50
        }
      }
    }
  }
}

# ---------- Exposition sur Internet ----------
resource "kubernetes_service_v1" "web" {
  metadata { name = "web-front" }
  spec {
    selector = { app = "web" }
    port {
      port        = 80
      target_port = 80
    }
    type = "LoadBalancer"
  }
}

output "web_url" {
  value = "http://${kubernetes_service_v1.web.status[0].load_balancer[0].ingress[0].ip}"
}
