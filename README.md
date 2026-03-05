# USDC → COP Cross-Border Payments API

A production-grade skeleton for a USDC→COP off-ramp API with extensible vendor architecture, full observability, Terraform IaC, and SOC 2-aligned infrastructure.

## Quick Start (Docker Compose)

```bash
# Clone and start the full stack
git clone <repo>
cd usdc-cop-api
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
| Grafana | http://localhost:3000 | Dashboards (admin/admin) |
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

### Txhash Validation Rules (Mock)
- `0x<hex>` with length ≥ 8 → `confirmed`
- `0xpending` → `pending` (→ 422)
- Anything else → `not found` (→ 422)

## Adding a New Vendor

1. Create `api/src/vendors/vendor_c.py` implementing `BaseVendor.process()`
2. In `api/src/main.py`: `vendor_registry.register("vendorC", VendorC())`
3. Add secret to Vault/SSM + `config.py`
4. Deploy — no other changes needed

## Infrastructure (Terraform + kind)

```bash
# Create local cluster
kind create cluster --name payments-local

# Deploy
cd infra/terraform
terraform init
terraform apply -var="environment=local"
```

## Programmatic Client

```bash
python scripts/client.py transfer --amount 100 --vendor vendorA --txhash 0x123abc
python scripts/client.py deploy-vendor --name vendorC --image vendorC:1.0.0
```

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — System design, vendor extensibility, request flow, observability, DORA metrics
- [`SOC2.md`](SOC2.md) — SOC 2 controls: IAM, encryption, audit logging, incident response

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
│   ├── Dockerfile
│   └── Dockerfile.blockchain-mock
├── infra/terraform/             # Kubernetes + Helm IaC
├── observability/               # Prometheus, Grafana, Loki, OTel configs
├── scripts/
│   ├── smoke-test.sh            # Post-deploy verification
│   └── client.py               # Programmatic API client
├── .github/workflows/ci-cd.yml  # GitHub Actions pipeline
├── docker-compose.yml
├── ARCHITECTURE.md
└── SOC2.md
```
