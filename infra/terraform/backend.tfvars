###############################################################################
# Backend region — must match aws_region in terraform.tfvars
# Terraform backend blocks do not support variable interpolation, so this is
# a separate file. Pass it on every init:
#   terraform init -backend-config=backend.tfvars
###############################################################################

region = "ap-south-1"
