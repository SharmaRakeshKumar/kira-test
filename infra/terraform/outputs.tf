output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = data.aws_eks_cluster.cluster.endpoint
}

output "api_ecr_url" {
  value = module.ecr.api_repository_url
}

output "blockchain_ecr_url" {
  value = module.ecr.blockchain_mock_repository_url
}

output "api_load_balancer_dns" {
  value       = try(kubernetes_service.payments_api.status[0].load_balancer[0].ingress[0].hostname, "pending")
  description = "DNS name of the ALB"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "configure_kubectl" {
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  description = "Run this to configure kubectl"
}

output "ci_role_arn" {
  value       = module.github_oidc.ci_role_arn
  description = "ARN to set as AWS_CI_ROLE_ARN in GitHub Actions secrets"
}