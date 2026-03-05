###############################################################################
# IRSA Module — IAM Roles for Service Accounts
# Allows the payments-api pod to call AWS APIs (SSM, ECR) without
# node-level credentials — SOC 2 least-privilege requirement
###############################################################################

variable "cluster_name"         { type = string }
variable "oidc_provider_arn"    { type = string }
variable "oidc_provider_url"    { type = string }
variable "namespace"            { type = string }
variable "service_account_name" { type = string }
variable "secrets_arns"         { type = list(string) }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  oidc_sub = "${replace(var.oidc_provider_url, "https://", "")}:sub"
  oidc_aud = "${replace(var.oidc_provider_url, "https://", "")}:aud"
}

# ── Payments API Role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "payments_api" {
  name = "${var.cluster_name}-payments-api-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_sub}" = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
          "${local.oidc_aud}" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "payments_api_ssm" {
  name = "ssm-read-secrets"
  role = aws_iam_role.payments_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = var.secrets_arns
    }]
  })
}

# ── ALB Controller Role ───────────────────────────────────────────────────────

data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.0/docs/install/iam_policy.json"
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_sub}" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_aud}" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "alb-controller-policy"
  role   = aws_iam_role.alb_controller.id
  policy = data.http.alb_controller_policy.response_body
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "role_arn"                { value = aws_iam_role.payments_api.arn }
output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }
