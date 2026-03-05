###############################################################################
# ECR Module — private repositories for API + blockchain mock images
###############################################################################

variable "project_name" { type = string }
variable "environment"  { type = string }

resource "aws_ecr_repository" "payments_api" {
  name                 = "${var.project_name}-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }

  encryption_configuration { encryption_type = "AES256" }

  tags = { Name = "${var.project_name}-api" }
}

resource "aws_ecr_repository" "blockchain_mock" {
  name                 = "${var.project_name}-blockchain-mock"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }

  encryption_configuration { encryption_type = "AES256" }

  tags = { Name = "${var.project_name}-blockchain-mock" }
}

# Lifecycle policy: keep last 10 images to save storage
resource "aws_ecr_lifecycle_policy" "payments_api" {
  repository = aws_ecr_repository.payments_api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "blockchain_mock" {
  repository = aws_ecr_repository.blockchain_mock.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

output "api_repository_url"             { value = aws_ecr_repository.payments_api.repository_url }
output "blockchain_mock_repository_url" { value = aws_ecr_repository.blockchain_mock.repository_url }
output "registry_id"                    { value = aws_ecr_repository.payments_api.registry_id }
