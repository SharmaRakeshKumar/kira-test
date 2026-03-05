#!/usr/bin/env bash
###############################################################################
# bootstrap-tfstate.sh
# Run ONCE manually (with a personal admin profile) before terraform init.
# Creates the S3 bucket and DynamoDB table for Terraform remote state + locking.
#
# Usage:
#   AWS_PROFILE=personal-admin bash scripts/bootstrap-tfstate.sh
#
# NOTE: Do NOT run this with the github-actions-ci user — it does not have
#       s3:CreateBucket or dynamodb:CreateTable permissions by design.
###############################################################################

# Do NOT use set -e here — aws describe-table exits non-zero when table
# does not exist, which would kill the script before we create it.
set -uo pipefail

REGION="ap-south-1"
BUCKET_NAME="usdc-cop-tfstate"    # must be globally unique — change if already taken
DYNAMO_TABLE="usdc-cop-tflock"
PROJECT_TAG="usdc-cop-payments"

echo "=== Bootstrapping Terraform remote state in $REGION ==="
echo "Using AWS identity: $(aws sts get-caller-identity --query Arn --output text)"
echo ""

###############################################################################
# 1. S3 bucket
###############################################################################

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "✓ S3 bucket $BUCKET_NAME already exists — skipping creation"
else
  echo "Creating S3 bucket $BUCKET_NAME ..."

  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"

  # Enable versioning (SOC 2: full audit trail of every state change)
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled

  # Enable AES-256 / KMS encryption at rest
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # Block all public access (SOC 2 requirement)
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "✓ S3 bucket $BUCKET_NAME created and secured"
fi

###############################################################################
# 2. DynamoDB table for state locking
#
# FIX: describe-table returns exit code 254 when the table does not exist.
# With set -e that would kill the script. We capture the exit code manually
# using "|| true" and check it explicitly instead.
###############################################################################

TABLE_STATUS=$(aws dynamodb describe-table \
  --table-name "$DYNAMO_TABLE" \
  --region "$REGION" \
  --query "Table.TableStatus" \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$TABLE_STATUS" != "NOT_FOUND" ]; then
  echo "✓ DynamoDB table $DYNAMO_TABLE already exists (status: $TABLE_STATUS) — skipping"
else
  echo "Creating DynamoDB table $DYNAMO_TABLE ..."

  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    --tags Key=Project,Value="$PROJECT_TAG"

  # Wait until ACTIVE before returning
  echo "Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists \
    --table-name "$DYNAMO_TABLE" \
    --region "$REGION"

  echo "✓ DynamoDB table $DYNAMO_TABLE created and active"
fi

###############################################################################
# Done
###############################################################################

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "S3 bucket   : $BUCKET_NAME"
echo "DynamoDB    : $DYNAMO_TABLE"
echo "Region      : $REGION"
echo ""
echo "These values are already set in infra/terraform/main.tf backend block."
echo "Next step:"
echo ""
echo "  cd infra/terraform"
echo "  AWS_PROFILE=personal-admin terraform init"
echo ""