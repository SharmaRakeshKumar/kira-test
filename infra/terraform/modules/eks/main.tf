###############################################################################
# EKS Module — managed node group, OIDC, CloudWatch logging
###############################################################################

variable "cluster_name"       { type = string }
variable "aws_region"         { type = string }
variable "kubernetes_version" { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "node_instance_type" { type = string }
variable "node_min_size"      { type = number }
variable "node_max_size"      { type = number }
variable "node_desired_size"  { type = number }

data "aws_caller_identity" "current" {}

# ── IAM Role for EKS Control Plane ───────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ── IAM Role for Node Group ───────────────────────────────────────────────────

resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy"    { policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy";          role = aws_iam_role.eks_nodes.name }
resource "aws_iam_role_policy_attachment" "eks_cni_policy"            { policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy";               role = aws_iam_role.eks_nodes.name }
resource "aws_iam_role_policy_attachment" "eks_ecr_readonly"          { policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly";  role = aws_iam_role.eks_nodes.name }
resource "aws_iam_role_policy_attachment" "eks_ssm_managed_instance"  { policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore";        role = aws_iam_role.eks_nodes.name }

# ── Security Group for cluster ────────────────────────────────────────────────

resource "aws_security_group" "eks_cluster" {
  name        = "${var.cluster_name}-sg"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-sg" }
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # SOC 2: enable control plane logging
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

# ── OIDC Provider (required for IRSA) ────────────────────────────────────────

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# ── Managed Node Group ────────────────────────────────────────────────────────

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2_x86_64"
  disk_size       = 50

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  update_config { max_unavailable = 1 }

  # SOC 2: enable node-level SSM for patching without SSH
  labels = { role = "worker"; environment = "eks" }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]

  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cluster_name"        { value = aws_eks_cluster.main.name }
output "cluster_endpoint"    { value = aws_eks_cluster.main.endpoint }
output "oidc_provider_arn"   { value = aws_iam_openid_connect_provider.eks.arn }
output "oidc_provider_url"   { value = aws_iam_openid_connect_provider.eks.url }
output "node_role_arn"       { value = aws_iam_role.eks_nodes.arn }
