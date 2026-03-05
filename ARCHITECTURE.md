# Architecture — USDC → COP Cross-Border Payments API

## Overview

This system accepts USDC→COP transfer requests, validates each request against an on-chain transaction hash, routes it to a configurable off-ramp vendor, and returns the vendor's response. The design prioritises **extensibility**, **observability**, and **SOC 2 alignment**.

---

## Component Diagram

```
                   ┌─────────────────────────────────────────────────────┐
                   │          AWS EKS Cluster (ap-south-1, 3 AZs)        │
                   │                                                     │
  HTTPS ──────────►│  AWS ALB (LoadBalancer service)                      │
                   │       │                                             │
                   │       ▼                                             │
                   │  ┌─────────────────────┐                            │
                   │  │   payments-api      │──► /metrics ──► Prometheus │
                   │  │   (FastAPI, 2+ pods)│──► structured logs ──► Loki│
                   │  └─────────┬───────────┘──► OTLP traces ──► OTel   │
                   │            │                                         │
                   │    ┌───────┴────────┐                               │
                   │    ▼                ▼                                │
                   │  blockchain-mock  vendor-registry                   │
                   │  (port 8001)      (in-process)                      │
                   │                   ├── VendorA                       │
                   │                   └── VendorB                       │
                   │                                                     │
                   │  Secrets: AWS SSM Parameter Store (via IRSA)        │
                   └─────────────────────────────────────────────────────┘
         │
         ├── ECR: payments-api image, blockchain-mock image
         ├── VPC: 3 private subnets (nodes) + 3 public subnets (ALB)
         └── IAM: IRSA role for pods; GitHub OIDC role for CI/CD

  CI/CD: GitHub Actions (OIDC auth) → test → terraform apply → build → deploy → smoke-test.sh
  Monitoring: Prometheus + Grafana + Loki (docker-compose locally; kube-prometheus-stack on EKS)
```

---

## Request Flow — POST /transfer

```
Client
  │
  │  POST /transfer {amount, vendor, txhash}
  ▼
AuditMiddleware          ← logs every request (SOC 2 audit trail)
  │
  ▼
Input validation         ← Pydantic: amount > 0, txhash regex, vendor alphanumeric
  │
  ▼
VendorRegistry.get()     ← returns vendor instance or 400
  │
  ▼
BlockchainService.confirm(txhash)
  │  GET http://blockchain-mock:8001/tx/{txhash}
  │  → "confirmed" | "pending" | "not found"
  │  TXHASH_CONFIRMATIONS counter incremented
  │
  ├── not confirmed → 422 Unprocessable Entity
  │
  ▼
vendor.process(amount, txhash, metadata)   ← VendorA or VendorB
  │  TRANSFER_LATENCY histogram observed
  │  TRANSFER_REQUESTS counter incremented
  │
  ▼
TransferResponse {request_id, status, vendor, txhash, vendor_response}
```

---

## Vendor Extensibility

Vendors implement a single abstract interface:

```python
class BaseVendor(ABC):
    @abstractmethod
    async def process(self, amount, txhash, metadata) -> dict: ...
```

**Adding VendorC requires exactly three steps:**

1. Create `api/src/vendors/vendor_c.py` subclassing `BaseVendor`
2. In `main.py`: `vendor_registry.register("vendorC", VendorC())`
3. Add `SECRET_VENDOR_C_KEY` to AWS SSM Parameter Store and `config.py`

No routing logic, no database migrations, no infrastructure changes. The registry pattern means zero coupling between vendors.

---

## Infrastructure as Code (Terraform)

### AWS Modules

| Module | Resources created |
|---|---|
| `module.vpc` | VPC, 3 private subnets (EKS nodes), 3 public subnets (ALB), NAT gateways, route tables |
| `module.eks` | EKS cluster (Kubernetes 1.31), managed node group (t3.medium, 2–6 nodes) |
| `module.ecr` | ECR repositories for `payments-api` and `blockchain-mock` |
| `module.secrets` | AWS SSM Parameter Store entries (KMS-encrypted) for vendor API keys |
| `module.irsa` | IAM Role for Service Accounts — pods assume this role to read SSM secrets |
| `module.github_oidc` | GitHub Actions OIDC provider + CI IAM role (no long-lived keys in CI) |

### Kubernetes Resources (via Terraform)

| Resource | Description |
|---|---|
| `kubernetes_namespace` | Isolated `payments` namespace |
| `kubernetes_deployment` | payments-api (rolling update, 2 replicas) |
| `kubernetes_deployment` | blockchain-mock |
| `kubernetes_secret` | Vendor API keys (sourced from SSM at apply time) |
| `kubernetes_service` | `type: LoadBalancer` → triggers AWS ALB Controller provisioning |
| `kubernetes_horizontal_pod_autoscaler_v2` | CPU-based autoscaling 2–10 pods |
| `helm_release` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| `helm_release` | AWS Load Balancer Controller |

**Local development**: `docker compose up -d` — no cloud account needed.
**Production**: AWS EKS in `ap-south-1` with S3 + DynamoDB Terraform backend (`usdc-cop-tfstate`).

---

## Observability

### Metrics (Prometheus)
| Metric | Type | Labels |
|---|---|---|
| `transfer_requests_total` | Counter | vendor, status |
| `transfer_latency_seconds` | Histogram | vendor |
| `txhash_confirmations_total` | Counter | result |
| `active_transfers` | Gauge | — |
| `deployment_info` | Gauge | version, environment, git_sha |

### Alert Rules (`observability/prometheus/alerts.yml`)
- `HighTransferErrorRate` — error rate > 5% per vendor (5m window)
- `HighTransferLatencyP99` — P99 latency > 2s per vendor
- `HighTxhashNotFoundRate` — > 20% of confirmations are "not found"
- `ActiveTransfersStuck` — `active_transfers > 50` for 5m
- `PaymentsAPIDown` / `BlockchainMockDown` — uptime alerts

### Logs (Loki + Promtail)
All logs are structured JSON via `structlog`. Every request is logged by `AuditMiddleware` with: method, path, status_code, latency_ms, client_ip. In production, ship to CloudWatch Logs for 7-year FINRA/SEC retention.

### Traces (OpenTelemetry → OTel Collector)
FastAPI is auto-instrumented. Each `/transfer` call produces a root span with child spans for blockchain validation and vendor processing. In production, export to AWS X-Ray or Tempo.

### Grafana Dashboards
Pre-provisioned dashboard at `observability/grafana/dashboards/payments-api.json` includes:
- Requests per vendor (RPS)
- P99 latency per vendor
- Success rate %
- Txhash confirmation distribution
- Active transfers gauge
- DORA deployment frequency timeline
- Error rate by vendor

---

## DORA Metrics

| DORA Metric | Collection Method |
|---|---|
| **Deployment Frequency** | `deployment_info` gauge: `changes(deployment_info[24h])` in Grafana |
| **Lead Time** | GitHub Actions: commit timestamp vs. `DEPLOY_TIME` env var written on success |
| **Change Failure Rate** | CI `::warning` annotation on deploy failure; ratio = failures / total deploys |
| **MTTR** | Time from failure annotation to next successful deploy; production: PagerDuty incident open→resolved |

---

## Local Quick Start

```bash
# 1. Start full local stack (API + blockchain mock + full observability)
cp .env.example .env          # set GRAFANA_ADMIN_PASSWORD
docker compose up -d

# 2. Run unit tests
cd api && pip install -r requirements.txt -r requirements-test.txt && pytest tests/ -v

# 3. Smoke tests against running stack
bash scripts/smoke-test.sh

# 4. Programmatic client
python scripts/client.py transfer --amount 100 --vendor vendorA --txhash 0x123abc

# 5. Grafana dashboards
open http://localhost:3000   # use GRAFANA_ADMIN_PASSWORD from .env
```

---

## Future Improvements

- **Vault integration**: Replace `kubernetes_secret` with Vault Agent Injector for zero-trust secret delivery
- **Idempotency / replay protection**: Store processed `txhash` values in Redis/DynamoDB with TTL
- **Webhook callbacks**: VendorB async status updates via outbound webhook handler
- **Rate limiting**: AWS WAF or API Gateway per-vendor rate limits
- **Dead letter queue**: SQS-backed retry queue for failed vendor calls
- **Multi-region**: Terraform workspaces per region; Route 53 latency routing
