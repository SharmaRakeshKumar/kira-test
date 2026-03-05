variable "project_name" {
  description = "Short name prefix for IAM resources"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in 'owner/repo' format (e.g. 'myorg/usdc-cop-api')"
  type        = string
}
