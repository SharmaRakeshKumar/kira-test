###############################################################################
# USDC → COP Payments API  —  AWS EKS  ap-south-1
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "usdc-cop-tfstate"
    key            = "payments-api/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "usdc-cop-tflock"
  }
}

###############################################################################
# Providers
###############################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "usdc-cop-payments"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_eks_cluster" "cluster" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

###############################################################################
# Modules
###############################################################################

module "vpc" {
  source          = "./modules/vpc"
  aws_region      = var.aws_region
  name            = "${var.project_name}-${var.environment}"
  vpc_cidr        = var.vpc_cidr
  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs
  cluster_name    = "${var.project_name}-${var.environment}"
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
  environment  = var.environment
}

module "eks" {
  source             = "./modules/eks"
  cluster_name       = "${var.project_name}-${var.environment}"
  aws_region         = var.aws_region
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  node_instance_type = var.node_instance_type
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  node_desired_size  = var.node_desired_size
}

module "secrets" {
  source       = "./modules/secrets"
  project_name = var.project_name
  environment  = var.environment
  vendor_a_key = var.vendor_a_key
  vendor_b_key = var.vendor_b_key
}

module "irsa" {
  source               = "./modules/irsa"
  cluster_name         = module.eks.cluster_name
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url
  namespace            = var.k8s_namespace
  service_account_name = "payments-api"
  secrets_arns         = module.secrets.secret_arns
}

###############################################################################
# Kubernetes Namespaces
###############################################################################

resource "kubernetes_namespace" "payments" {
  metadata {
    name = var.k8s_namespace
    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      managed-by = "terraform"
    }
  }
  depends_on = [module.eks]
}

###############################################################################
# Service Account (IRSA)
###############################################################################

resource "kubernetes_service_account" "payments_api" {
  metadata {
    name      = "payments-api"
    namespace = kubernetes_namespace.payments.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa.role_arn
    }
  }
}

###############################################################################
# Kubernetes Secret
###############################################################################

resource "kubernetes_secret" "vendor_keys" {
  metadata {
    name      = "vendor-api-keys"
    namespace = kubernetes_namespace.payments.metadata[0].name
    annotations = {
      "soc2/classification" = "confidential"
    }
  }
  type = "Opaque"
  data = {
    VENDOR_A_KEY = var.vendor_a_key
    VENDOR_B_KEY = var.vendor_b_key
  }
}

###############################################################################
# Payments API Deployment
###############################################################################

resource "kubernetes_deployment" "payments_api" {
  metadata {
    name      = "payments-api"
    namespace = kubernetes_namespace.payments.metadata[0].name
    labels = {
      app     = "payments-api"
      version = var.api_image_tag
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "8000"
      "prometheus.io/path"   = "/metrics"
    }
  }

  spec {
    replicas = var.api_replicas

    selector {
      match_labels = {
        app = "payments-api"
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "25%"
        max_surge       = "25%"
      }
    }

    template {
      metadata {
        labels = {
          app     = "payments-api"
          version = var.api_image_tag
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8000"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.payments_api.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          fs_group        = 1000
        }

        container {
          name              = "payments-api"
          image             = "${module.ecr.api_repository_url}:${var.api_image_tag}"
          image_pull_policy = "Always"

          port {
            container_port = 8000
          }

          env {
            name  = "ENVIRONMENT"
            value = var.environment
          }

          env {
            name  = "BLOCKCHAIN_SERVICE_URL"
            value = "http://blockchain-mock.${var.k8s_namespace}.svc.cluster.local:8001"
          }

          env {
            name  = "GIT_SHA"
            value = var.git_sha
          }

          env {
            name  = "APP_VERSION"
            value = var.api_image_tag
          }

          env {
            name  = "OTLP_ENDPOINT"
            value = "http://opentelemetry-collector.monitoring.svc.cluster.local:4318/v1/traces"
          }

          env {
            name = "SECRET_VENDOR_A_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.vendor_keys.metadata[0].name
                key  = "VENDOR_A_KEY"
              }
            }
          }

          env {
            name = "SECRET_VENDOR_B_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.vendor_keys.metadata[0].name
                key  = "VENDOR_B_KEY"
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }

  depends_on = [module.eks, kubernetes_namespace.payments]
}

###############################################################################
# Blockchain Mock Deployment
###############################################################################

resource "kubernetes_deployment" "blockchain_mock" {
  metadata {
    name      = "blockchain-mock"
    namespace = kubernetes_namespace.payments.metadata[0].name
    labels = {
      app = "blockchain-mock"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "blockchain-mock"
      }
    }

    template {
      metadata {
        labels = {
          app = "blockchain-mock"
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
        }

        container {
          name              = "blockchain-mock"
          image             = "${module.ecr.blockchain_mock_repository_url}:${var.api_image_tag}"
          image_pull_policy = "Always"

          port {
            container_port = 8001
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8001
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [module.eks, kubernetes_namespace.payments]
}

###############################################################################
# Services
###############################################################################

resource "kubernetes_service" "payments_api" {
  metadata {
    name      = "payments-api"
    namespace = kubernetes_namespace.payments.metadata[0].name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"   = "external"
      "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
    }
  }

  spec {
    selector = {
      app = "payments-api"
    }
    port {
      port        = 80
      target_port = 8000
    }
    type = "LoadBalancer"
  }
}

resource "kubernetes_service" "blockchain_mock" {
  metadata {
    name      = "blockchain-mock"
    namespace = kubernetes_namespace.payments.metadata[0].name
  }

  spec {
    selector = {
      app = "blockchain-mock"
    }
    port {
      port        = 8001
      target_port = 8001
    }
    type = "ClusterIP"
  }
}

###############################################################################
# Horizontal Pod Autoscaler
###############################################################################

resource "kubernetes_horizontal_pod_autoscaler_v2" "payments_api" {
  metadata {
    name      = "payments-api-hpa"
    namespace = kubernetes_namespace.payments.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.payments_api.metadata[0].name
    }
    min_replicas = var.api_replicas
    max_replicas = var.api_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}

###############################################################################
# Observability — kube-prometheus-stack
###############################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = false
  version          = "65.3.1"
  timeout          = 600

  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "grafana.persistence.enabled"
    value = "true"
  }

  set {
    name  = "grafana.persistence.size"
    value = "5Gi"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "20Gi"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
    value = "gp2"
  }

  depends_on = [kubernetes_namespace.monitoring, module.eks]
}

###############################################################################
# AWS Load Balancer Controller
###############################################################################

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.9.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa.alb_controller_role_arn
  }

  depends_on = [module.eks]
}
