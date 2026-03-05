#!/usr/bin/env bash
###############################################################################
# bootstrap-tfstate.sh
# Run ONCE manually before your first terraform init.
# Creates the S3 bucket and DynamoDB table for remote state + locking.
#
# Usage:
#   AWS_PROFILE=your-profile bash scripts/bootstrap-tfstate.sh
###############################################################################
set -euo pipefail

REGION="ap-south-1"
BUCKET_NAME="usdc-cop-tfstate"          # must be globally unique — change if taken
DYNAMO_TABLE="usdc-cop-tflock"
PROJECT_TAG="usdc-cop-payments"

echo "=== Bootstrapping Terraform remote state in $REGION ==="

# 1. Create S3 bucket
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Bucket $BUCKET_NAME already exists — skipping creation"
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"

  # Enable versioning (SOC 2: audit trail of state changes)
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled

  # Enable server-side encryption
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

  # Block all public access (SOC 2)
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "✓ S3 bucket $BUCKET_NAME created"
fi

# 2. Create DynamoDB table for state locking
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$REGION" 2>/dev/null; then
  echo "DynamoDB table $DYNAMO_TABLE already exists — skipping"
else
  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    --tags Key=Project,Value="$PROJECT_TAG"

  echo "✓ DynamoDB table $DYNAMO_TABLE created"
fi

echo ""
echo "=== Done. Now update infra/terraform/main.tf backend block with: ==="
echo "  bucket = \"$BUCKET_NAME\""
echo "  dynamodb_table = \"$DYNAMO_TABLE\""
echo "  region = \"$REGION\""
echo ""
echo "Then run: cd infra/terraform && terraform init"
