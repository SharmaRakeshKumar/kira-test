###############################################################################
# USDC → COP Payments API  —  AWS EKS  ap-south-1
# Core AWS infrastructure only (VPC, EKS, ECR, IAM, Secrets)
# Kubernetes workloads are in workloads.tf
###############################################################################

terraform {
  required_version = ">= 1.5"

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
# Modules — core AWS infrastructure
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

module "github_oidc" {
  source       = "./modules/github-oidc"
  project_name = var.project_name
  github_repo  = var.github_repo
}