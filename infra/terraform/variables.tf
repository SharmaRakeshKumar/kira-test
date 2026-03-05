###############################################################################
# Variables — edit these before running terraform apply
###############################################################################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short name prefix for all resources"
  type        = string
  default     = "usdc-cop"
}

variable "environment" {
  description = "Environment name (dev | staging | prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to use in ap-south-1"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (EKS nodes live here)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (ALB lives here)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 6
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "k8s_namespace" {
  description = "Kubernetes namespace for the payments app"
  type        = string
  default     = "payments"
}

variable "api_image_tag" {
  description = "Docker image tag to deploy (set by CI/CD)"
  type        = string
  default     = "latest"
}

variable "git_sha" {
  description = "Git commit SHA (set by CI/CD for DORA metrics)"
  type        = string
  default     = "unknown"
}

variable "api_replicas" {
  description = "Minimum API pod replicas"
  type        = number
  default     = 2
}

variable "api_max_replicas" {
  description = "Maximum API pod replicas (HPA ceiling)"
  type        = number
  default     = 10
}

# Sensitive — pass via GitHub Actions secrets, never hardcode
variable "vendor_a_key" {
  description = "VendorA API key"
  type        = string
  sensitive   = true
  default     = "mock-vendor-a-key"
}

variable "vendor_b_key" {
  description = "VendorB API key"
  type        = string
  sensitive   = true
  default     = "mock-vendor-b-key"
}

variable "github_repo" {
  description = "GitHub repository in 'owner/repo' format — used to scope the OIDC CI role"
  type        = string
  default     = "your-org/usdc-cop-api"
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
  default     = "ChangeMe123!"
}
