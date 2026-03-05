###############################################################################
# Secrets Module — AWS SSM Parameter Store (SecureString)
# SOC 2: secrets encrypted at rest with KMS, access controlled via IAM
###############################################################################

variable "project_name" { type = string }
variable "environment"  { type = string }
variable "vendor_a_key" { type = string; sensitive = true }
variable "vendor_b_key" { type = string; sensitive = true }

# ── KMS key for secret encryption ────────────────────────────────────────────

resource "aws_kms_key" "secrets" {
  description             = "${var.project_name}-${var.environment} secrets encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true    # SOC 2: automatic annual rotation

  tags = { Name = "${var.project_name}-${var.environment}-secrets-key" }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-${var.environment}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ── SSM Parameters ────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "vendor_a_key" {
  name        = "/${var.project_name}/${var.environment}/vendor-a-key"
  description = "VendorA API key"
  type        = "SecureString"
  value       = var.vendor_a_key
  key_id      = aws_kms_key.secrets.arn
  tags        = { classification = "confidential" }
}

resource "aws_ssm_parameter" "vendor_b_key" {
  name        = "/${var.project_name}/${var.environment}/vendor-b-key"
  description = "VendorB API key"
  type        = "SecureString"
  value       = var.vendor_b_key
  key_id      = aws_kms_key.secrets.arn
  tags        = { classification = "confidential" }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "kms_key_arn"  { value = aws_kms_key.secrets.arn }
output "secret_arns"  {
  value = [
    aws_ssm_parameter.vendor_a_key.arn,
    aws_ssm_parameter.vendor_b_key.arn,
  ]
}
