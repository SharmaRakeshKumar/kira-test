# SOC 2 Alignment

This document describes how the USDC→COP payments infrastructure supports the five SOC 2 Trust Service Criteria (TSC): Security, Availability, Processing Integrity, Confidentiality, and Privacy.

---

## CC6 — Logical and Physical Access Controls

### Identity and Access Management (IAM)

| Control | Implementation |
|---|---|
| Least-privilege service accounts | Each Kubernetes `ServiceAccount` has only the permissions needed for its workload |
| Secret scoping | `kubernetes_secret` vendor keys are namespace-scoped; pods mount only the keys they need via `secretKeyRef` |
| No root containers | `runAsNonRoot: true` + `runAsUser: 1000` in all pod specs |
| RBAC enforcement | Kubernetes RBAC roles restrict `get/list/watch` on secrets to the `payments` namespace only |

### Production upgrade path
In production, replace `kubernetes_secret` with **HashiCorp Vault** dynamic secrets:
- Vault Agent Injector injects short-lived credentials into pods at runtime
- Credentials are rotated automatically (TTL-based)
- All Vault access is audited via Vault audit log → SIEM

### API Authentication
- All API endpoints require a bearer token (JWT) verified against an IdP (e.g., Auth0, Cognito) — add via FastAPI `Depends(verify_token)` middleware
- CI/CD secrets (`VENDOR_A_KEY`, etc.) are stored in GitHub Actions Secrets (encrypted at rest, never in source)

---

## CC6.7 — Data Security in Transit and at Rest

### Encryption in Transit (TLS)
| Layer | Implementation |
|---|---|
| Client → Ingress | TLS 1.2+ enforced by nginx-ingress annotation `ssl-redirect: "true"` |
| Ingress → Pod | mTLS via Linkerd/Istio service mesh (production) |
| Pod → blockchain-mock | Internal cluster traffic (upgradeable to mTLS) |

### Encryption at Rest
| Resource | Encryption |
|---|---|
| `kubernetes_secret` | Encrypted by Kubernetes etcd encryption provider (AES-256 or KMS) |
| Terraform state | S3 backend with `encrypt = true` + KMS CMK |
| Prometheus TSDB | Encrypted EBS volume (production) |
| Loki object storage | S3 SSE-S3 or SSE-KMS |

### Sensitive Data Handling
- `txhash` values are logged for audit purposes but never alongside PII
- Vendor API keys are never logged; structured log context explicitly excludes secret fields
- Amount values are logged at INFO level for auditability

---

## CC7 — System Monitoring and Incident Response

### Audit Logging

Every inbound HTTP request is written to structured JSON via `AuditMiddleware`:

```json
{
  "event": "http_request",
  "timestamp": "2025-01-15T10:23:41Z",
  "method": "POST",
  "path": "/transfer",
  "status_code": 200,
  "latency_ms": 142.5,
  "client_ip": "10.0.1.5",
  "request_id": "a3f9b2c1-...",
  "vendor": "vendorA",
  "txhash": "0x123abc"
}
```

**Key audit events:**
| Event | Log Level | Fields |
|---|---|---|
| Transfer request received | INFO | request_id, vendor, txhash, amount |
| Txhash validated | INFO | request_id, txhash, result |
| Txhash not confirmed | WARNING | request_id, txhash, tx_result |
| Transfer complete | INFO | request_id, vendor, duration_ms, vendor_status |
| Transfer error | ERROR | request_id, error, stack_trace |
| Unknown vendor | WARNING | request_id, vendor |
| Service startup | INFO | version, environment, git_sha |

Logs are shipped to **Loki** (append-only) via Promtail. In production, use CloudWatch Logs with a resource policy preventing deletion for 7 years (FINRA/SEC compliance).

### Txhash Validation as a Control
The mandatory blockchain confirmation step (`BlockchainService.confirm()`) ensures:
- No transfer is processed without an on-chain proof of deposit
- All confirmation results are counted in `txhash_confirmations_total` metric
- Failed confirmations are logged at WARNING and blocked before vendor call

This creates a **tamper-evident audit trail** correlating each off-ramp transfer to a specific on-chain transaction.

### Incident Response

| Phase | Mechanism |
|---|---|
| **Detection** | Prometheus alert rules (error rate > 5%, latency p99 > 2s, active_transfers stuck) → Alertmanager → PagerDuty |
| **Containment** | Kubernetes HPA scale-down; circuit breaker (Resilience4j/tenacity) to stop vendor calls |
| **Recovery** | Rolling redeploy via `kubectl rollout restart`; MTTR tracked as DORA metric |
| **Post-incident** | Loki log retention + Prometheus long-term storage (Thanos/Cortex) for retrospective analysis |

**DORA Change Failure Rate** is recorded in CI: when a deploy job fails, a GitHub Actions `warning` annotation is written and can be exported to an incident tracking system. MTTR is the duration between the failure annotation and the next successful deploy timestamp.

---

## CC8 — Change Management

| Control | Implementation |
|---|---|
| All infra changes via IaC | Terraform — no manual `kubectl apply` in production |
| Plan before apply | `terraform plan` runs on every PR; `terraform apply` only on merge to `main` |
| Image immutability | Docker images tagged by Git SHA; `latest` tag also pushed but deploys use SHA tag |
| Deployment tests gate rollout | `smoke-test.sh` must pass or pipeline fails and deployment is rolled back |
| Secrets rotation | Vault TTL-based rotation (production); GitHub Actions secret rotation via org-level secret management |

---

## CC9 — Risk Mitigation

| Risk | Mitigation |
|---|---|
| Vendor unavailability | Multiple vendors; future circuit-breaker pattern; vendor health exposed via `/ready` |
| Double-spend / replay | `txhash` uniqueness check (idempotency key); store processed hashes in Redis with TTL |
| Secrets leakage | Secrets only in environment variables from Kubernetes Secrets / Vault; never in source code or logs |
| Container escape | Non-root user; read-only root filesystem (production); Pod Security Admission |
| Supply chain attacks | Dependabot for dependency updates; Docker image signing (Cosign) |

---

## Availability (A1)

| Control | Implementation |
|---|---|
| Redundancy | Minimum 2 API replicas via HPA `minReplicas: 2` |
| Auto-scaling | HPA scales to 10 pods on CPU > 70% |
| Health probes | Liveness + readiness probes prevent traffic to unhealthy pods |
| Rolling updates | `maxUnavailable: 25%` ensures continuous availability during deploys |
| Resource limits | CPU/memory limits prevent noisy-neighbour resource starvation |

---

## Processing Integrity (PI1)

| Control | Implementation |
|---|---|
| Input validation | Pydantic models enforce: `amount > 0`, `txhash` regex, `vendor` alphanumeric |
| Blockchain proof required | Every transfer blocked until txhash returns `"confirmed"` |
| Request traceability | Every transfer has a unique `request_id` (UUID v4) returned to caller |
| Idempotency | `request_id` can be used as idempotency key for retry-safe integrations |

---

## Summary Mapping to SOC 2 Criteria

| TSC | Key Controls |
|---|---|
| CC6 (Access) | RBAC, non-root containers, Vault secrets, JWT auth |
| CC6.7 (Encryption) | TLS ingress, etcd encryption, S3 SSE, no secrets in logs |
| CC7 (Monitoring) | Structured audit logs → Loki, Prometheus alerting, incident runbooks |
| CC8 (Change Mgmt) | Terraform IaC, SHA-tagged images, smoke tests gate deployment |
| CC9 (Risk) | Multi-vendor, idempotency keys, Dependabot, image signing |
| A1 (Availability) | 2+ replicas, HPA, rolling updates, health probes |
| PI1 (Integrity) | Pydantic validation, blockchain proof, request traceability |
