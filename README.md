# USDC → COP Cross-Border Payments API

A production-grade skeleton for a USDC→COP off-ramp API with extensible vendor architecture, full observability, Terraform IaC on AWS EKS, and SOC 2-aligned infrastructure.

## Quick Start (Docker Compose)

```bash
# Clone and start the full stack
git clone <repo>
cd usdc-cop-api

# Set local secrets (Grafana password, etc.)
cp .env.example .env

# Start all services
docker compose up -d

# Run unit tests
cd api
pip install -r requirements.txt -r requirements-test.txt
pytest tests/ -v

# Smoke tests against running stack
bash scripts/smoke-test.sh

# Call the API
curl -X POST http://localhost:8000/transfer \
  -H "Content-Type: application/json" \
  -d '{"amount": 100, "vendor": "vendorA", "txhash": "0x123abc"}'
```

## Services

| Service | URL | Description |
|---|---|---|
| Payments API | http://localhost:8000 | Main API |
| Blockchain Mock | http://localhost:8001 | Mock tx validator |
| Prometheus | http://localhost:9090 | Metrics |
| Grafana | http://localhost:3000 | Dashboards (see `.env` for password) |
| Loki | http://localhost:3100 | Log aggregation |

## API Endpoints

### `POST /transfer`
```json
// Request
{ "amount": 100, "vendor": "vendorA", "txhash": "0x123abc" }

// Response (vendorA)
{
  "request_id": "uuid",
  "status": "success",
  "vendor": "vendorA",
  "txhash": "0x123abc",
  "vendor_response": { "status": "success", "amount_cop": 420000 }
}

// Response (vendorB)
{
  "vendor_response": { "status": "pending", "estimated_completion_minutes": 15 }
}
```

### Txhash Validation Rules (Blockchain Mock)
| txhash | Result | API response |
|---|---|---|
| `0x<hex>` length ≥ 8 | `confirmed` | 200 |
| `0xpending` | `pending` | 422 |
| `0xdeaddead` | `not found` (test sentinel) | 422 |
| Invalid format | rejected by Pydantic | 422 |

## Adding a New Vendor

1. Create `api/src/vendors/vendor_c.py` implementing `BaseVendor.process()`
2. In `api/src/main.py`: `vendor_registry.register("vendorC", VendorC())`
3. Add secret to AWS SSM Parameter Store + `config.py`
4. Deploy — no other changes needed

## Infrastructure (Terraform + AWS EKS)

```bash
# Configure AWS credentials
aws configure   # or use the GitHub Actions OIDC role after bootstrap

# Deploy to EKS (ap-south-1)
cd infra/terraform
terraform init
terraform apply \
  -var="vendor_a_key=..." \
  -var="vendor_b_key=..." \
  -var="grafana_admin_password=..."

# Get kubeconfig
$(terraform output -raw configure_kubectl)

# After first apply: set the CI role ARN in GitHub secrets
terraform output ci_role_arn
# → add as AWS_CI_ROLE_ARN in repo secrets, then remove AWS_ACCESS_KEY_ID/SECRET
```

**AWS resources provisioned:** VPC (3 AZs), EKS cluster, ECR repos, SSM Parameter Store (vendor keys), IRSA role (pod → SSM), GitHub OIDC role (CI → AWS), ALB Controller, kube-prometheus-stack.

## Programmatic Client

```bash
# Submit a transfer
python scripts/client.py transfer --amount 100 --vendor vendorA --txhash 0x123abc

# Trigger CI/CD pipeline (requires GITHUB_TOKEN + GITHUB_REPO env vars)
python scripts/client.py deploy-vendor --name vendorC --image vendorC:1.0.0
```

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — System design, AWS infrastructure, vendor extensibility, request flow, observability, DORA metrics
- [`SOC2.md`](SOC2.md) — SOC 2 controls: IAM/IRSA, encryption, audit logging, incident response

## Project Structure

```
.
├── api/
│   ├── src/
│   │   ├── main.py              # FastAPI app, metrics, tracing
│   │   ├── models.py            # Pydantic request/response models
│   │   ├── config.py            # Settings (env-based)
│   │   ├── services/
│   │   │   ├── base_vendor.py   # Abstract vendor interface
│   │   │   ├── vendor_registry.py
│   │   │   └── blockchain.py    # Blockchain validation client
│   │   ├── vendors/
│   │   │   ├── vendor_a.py      # Returns {"status": "success"}
│   │   │   ├── vendor_b.py      # Returns {"status": "pending"}
│   │   │   └── vendor_c_stub.py # Template for new vendors
│   │   └── middleware/
│   │       └── audit.py         # SOC 2 audit trail
│   ├── blockchain_mock/         # Mock blockchain service
│   ├── tests/                   # Pytest unit + integration tests
│   ├── Dockerfile               # Multi-stage build (builder + lean runtime)
│   └── Dockerfile.blockchain-mock
├── infra/terraform/
│   ├── main.tf                  # AWS providers + module wiring
│   ├── workloads.tf             # Kubernetes resources
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── vpc/                 # VPC, subnets, NAT
│       ├── eks/                 # EKS cluster + node group
│       ├── ecr/                 # ECR repositories
│       ├── secrets/             # SSM Parameter Store
│       ├── irsa/                # IAM Role for Service Accounts
│       └── github-oidc/        # GitHub Actions OIDC role
├── observability/               # Prometheus, Grafana, Loki, OTel configs
├── scripts/
│   ├── smoke-test.sh            # Post-deploy verification (blocks CI on failure)
│   └── client.py               # Programmatic API client
├── .github/workflows/ci-cd.yml  # GitHub Actions: test → infra → build → deploy → smoke
├── .env.example                 # Local env template
├── docker-compose.yml
├── ARCHITECTURE.md
└── SOC2.md
```
