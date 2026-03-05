###############################################################################
# GitHub Actions OIDC — short-lived credentials for CI/CD
# Creates an IAM OIDC provider for GitHub and a CI role that can be assumed
# by GitHub Actions workflows in the configured repository.
###############################################################################

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint (stable; update only if GitHub rotates their cert)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_ci" {
  name = "${var.project_name}-github-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to pushes/PRs on the configured repo only
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_ci" {
  name = "${var.project_name}-github-ci-policy"
  role = aws_iam_role.github_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR — push images
      {
        Effect   = "Allow"
        Action   = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = "*"
      },
      # EKS — update kubeconfig
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:*:${data.aws_caller_identity.current.account_id}:cluster/*"
      },
      # S3 + DynamoDB — Terraform state backend
      {
        Effect   = "Allow"
        Action   = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket",
          "s3:CreateBucket", "s3:PutBucketVersioning",
          "s3:PutBucketEncryption", "s3:PutPublicAccessBlock",
        ]
        Resource = [
          "arn:aws:s3:::usdc-cop-tfstate",
          "arn:aws:s3:::usdc-cop-tfstate/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem",
          "dynamodb:DescribeTable", "dynamodb:CreateTable",
        ]
        Resource = "arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/usdc-cop-tflock"
      },
      # IAM — Terraform needs to manage roles/policies
      {
        Effect   = "Allow"
        Action   = [
          "iam:GetRole", "iam:GetRolePolicy", "iam:CreateRole", "iam:DeleteRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:TagRole", "iam:UntagRole",
          "iam:GetOpenIDConnectProvider", "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
          "iam:GetPolicy", "iam:CreatePolicy", "iam:DeletePolicy",
          "iam:ListPolicyVersions",
          "iam:PassRole",
        ]
        Resource = "*"
      },
      # VPC / EC2 — Terraform manages networking
      {
        Effect   = "Allow"
        Action   = [
          "ec2:*",
          "elasticloadbalancing:*",
        ]
        Resource = "*"
      },
      # SSM — vendor API keys
      {
        Effect   = "Allow"
        Action   = [
          "ssm:PutParameter", "ssm:GetParameter", "ssm:DeleteParameter",
          "ssm:DescribeParameters", "ssm:AddTagsToResource",
          "ssm:ListTagsForResource",
        ]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/usdc-cop/*"
      },
      # KMS — Terraform state encryption
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = "*"
      },
    ]
  })
}
