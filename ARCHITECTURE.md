# Architecture — USDC → COP Cross-Border Payments API

## Overview

This system accepts USDC→COP transfer requests, validates each request against an on-chain transaction hash, routes it to a configurable off-ramp vendor, and returns the vendor's response. The design prioritises **extensibility**, **observability**, and **SOC 2 alignment**.

---

## Component Diagram

```
                   ┌───────────────────────────────────────────────┐
                   │            Kubernetes Cluster (kind/EKS)       │
                   │                                               │
  HTTPS ──────────►│  Ingress (nginx/ALB)                          │
                   │       │                                       │
                   │       ▼                                       │
                   │  ┌─────────────────────┐                      │
                   │  │   payments-api      │──► /metrics ──► Prometheus
                   │  │   (FastAPI, 2+ pods)│──► structured logs ──► Loki
                   │  └─────────┬───────────┘──► OTLP traces ──► OTel Collector
                   │            │                                   │
                   │    ┌───────┴────────┐                         │
                   │    ▼                ▼                          │
                   │  blockchain-mock  vendor-registry              │
                   │  (port 8001)      (in-process)                 │
                   │                   ├── VendorA                  │
                   │                   └── VendorB                  │
                   │                                               │
                   │  Secrets: kubernetes_secret (→ Vault in prod) │
                   └───────────────────────────────────────────────┘

  CI/CD: GitHub Actions → build → test → terraform apply → smoke-test.sh
  Monitoring: Prometheus + Grafana + Loki (docker-compose or Helm)
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
3. Add `SECRET_VENDOR_C_KEY` to Vault/SSM and `config.py`

No routing logic, no database migrations, no infrastructure changes. The registry pattern means zero coupling between vendors.

---

## Infrastructure as Code (Terraform)

| Resource | Description |
|---|---|
| `kubernetes_namespace` | Isolated namespace with environment labels |
| `kubernetes_deployment` | payments-api (rolling update, 2 replicas) |
| `kubernetes_deployment` | blockchain-mock |
| `kubernetes_secret` | Vendor API keys (sensitive, encrypted at rest) |
| `kubernetes_service` | ClusterIP for both services |
| `kubernetes_ingress_v1` | TLS-terminating ingress |
| `kubernetes_horizontal_pod_autoscaler_v2` | CPU-based autoscaling 2–10 pods |
| `helm_release` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |

**Local**: Uses `kind` (Kubernetes in Docker) — no cloud account needed.  
**Production**: Switch `provider "kubernetes"` to EKS/GKE endpoint, add S3 backend for state, and replace `kubernetes_secret` with Vault dynamic secrets.

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

### Logs (Loki + Promtail)
All logs are structured JSON via `structlog`. Every request is logged by `AuditMiddleware` with: method, path, status_code, latency_ms, client_ip.

### Traces (OpenTelemetry → OTel Collector)
FastAPI is auto-instrumented. Each `/transfer` call produces a root span with child spans for blockchain validation and vendor processing. In production, export to Tempo or Jaeger.

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
| **Lead Time** | GitHub Actions: `git log` timestamp of commit vs. `DEPLOY_TIME` env var written on success |
| **Change Failure Rate** | CI job `Record DORA failure event` step fires on deploy failure; ratio = failures / total deploys |
| **MTTR** | Mock: time from failure annotation to next successful deploy; production: PagerDuty incident open→resolved duration |

---

## Local Quick Start

```bash
# 1. Start full stack
docker compose up -d

# 2. Run unit tests
cd api && pip install -r requirements-test.txt && pytest tests/ -v

# 3. Smoke tests (requires docker compose to be up)
bash scripts/smoke-test.sh

# 4. Programmatic client
python scripts/client.py transfer --amount 100 --vendor vendorA --txhash 0x123abc

# 5. Grafana dashboards
open http://localhost:3000  # admin/admin
```

---

## Future Improvements

- **Vault integration**: Replace `kubernetes_secret` with Vault Agent Injector for zero-trust secret delivery
- **Webhook callbacks**: VendorB async status updates via outbound webhook handler
- **Rate limiting**: nginx-ingress or API gateway per-vendor rate limits
- **Dead letter queue**: SQS/Redis-backed retry queue for failed vendor calls
- **Multi-region**: Terraform workspaces per region; Route 53 latency routing
