import time
import uuid
import logging
import structlog
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse
from prometheus_client import make_asgi_app, Counter, Histogram, Gauge
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from .models import TransferRequest, TransferResponse
from .services.blockchain import BlockchainService
from .services.vendor_registry import VendorRegistry
from .vendors.vendor_a import VendorA
from .vendors.vendor_b import VendorB
from .middleware.audit import AuditMiddleware
from .config import settings

# ── Structured logging ────────────────────────────────────────────────────────
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.stdlib.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer(),
    ]
)
logger = structlog.get_logger()

# ── Prometheus metrics ────────────────────────────────────────────────────────
TRANSFER_REQUESTS = Counter(
    "transfer_requests_total",
    "Total transfer requests",
    ["vendor", "status"],
)
TRANSFER_LATENCY = Histogram(
    "transfer_latency_seconds",
    "Transfer request latency",
    ["vendor"],
    buckets=[0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)
TXHASH_CONFIRMATIONS = Counter(
    "txhash_confirmations_total",
    "Txhash confirmation outcomes",
    ["result"],
)
ACTIVE_TRANSFERS = Gauge(
    "active_transfers",
    "Currently processing transfers",
)
DEPLOYMENT_INFO = Gauge(
    "deployment_info",
    "Deployment metadata for DORA metrics",
    ["version", "environment", "git_sha"],
)


# ── App lifespan ──────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Record deployment event (DORA: deployment frequency)
    DEPLOYMENT_INFO.labels(
        version=settings.APP_VERSION,
        environment=settings.ENVIRONMENT,
        git_sha=settings.GIT_SHA,
    ).set(time.time())
    logger.info(
        "startup",
        version=settings.APP_VERSION,
        environment=settings.ENVIRONMENT,
        git_sha=settings.GIT_SHA,
    )
    yield
    logger.info("shutdown")


# ── OpenTelemetry tracing ─────────────────────────────────────────────────────
def setup_tracing():
    provider = TracerProvider()
    if settings.OTLP_ENDPOINT:
        exporter = OTLPSpanExporter(endpoint=settings.OTLP_ENDPOINT)
        provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)


setup_tracing()

app = FastAPI(
    title="USDC → COP Cross-Border Payments API",
    version=settings.APP_VERSION,
    lifespan=lifespan,
)

# Mount Prometheus metrics endpoint
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

# Instrument with OpenTelemetry
FastAPIInstrumentor.instrument_app(app)

# Audit middleware (SOC 2 requirement)
app.add_middleware(AuditMiddleware)

# ── Dependency injection ──────────────────────────────────────────────────────
blockchain_service = BlockchainService()
vendor_registry = VendorRegistry()
vendor_registry.register("vendorA", VendorA())
vendor_registry.register("vendorB", VendorB())
# Adding vendorC in future: vendor_registry.register("vendorC", VendorC())


# ── Routes ────────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "version": settings.APP_VERSION}


@app.get("/ready")
async def ready():
    """Kubernetes readiness probe."""
    return {"status": "ready", "vendors": vendor_registry.list_vendors()}


@app.post("/transfer", response_model=TransferResponse)
async def transfer(request: TransferRequest, http_request: Request):
    request_id = str(uuid.uuid4())
    log = logger.bind(
        request_id=request_id,
        vendor=request.vendor,
        txhash=request.txhash,
        amount=request.amount,
    )

    ACTIVE_TRANSFERS.inc()
    start = time.time()

    try:
        # 1. Validate vendor exists
        vendor = vendor_registry.get(request.vendor)
        if not vendor:
            TRANSFER_REQUESTS.labels(vendor=request.vendor, status="invalid_vendor").inc()
            log.warning("unknown_vendor")
            raise HTTPException(status_code=400, detail=f"Unknown vendor: {request.vendor}")

        # 2. Validate txhash with blockchain service
        log.info("validating_txhash")
        tx_result = await blockchain_service.confirm(request.txhash)
        TXHASH_CONFIRMATIONS.labels(result=tx_result).inc()

        if tx_result != "confirmed":
            TRANSFER_REQUESTS.labels(vendor=request.vendor, status="tx_not_found").inc()
            log.warning("txhash_not_confirmed", tx_result=tx_result)
            raise HTTPException(status_code=422, detail=f"Transaction not confirmed: {tx_result}")

        log.info("txhash_confirmed")

        # 3. Forward to vendor
        log.info("forwarding_to_vendor")
        vendor_response = await vendor.process(
            amount=request.amount,
            txhash=request.txhash,
            metadata=request.metadata or {},
        )

        duration = time.time() - start
        TRANSFER_LATENCY.labels(vendor=request.vendor).observe(duration)
        TRANSFER_REQUESTS.labels(vendor=request.vendor, status="success").inc()

        log.info(
            "transfer_complete",
            duration_ms=round(duration * 1000, 2),
            vendor_status=vendor_response.get("status"),
        )

        return TransferResponse(
            request_id=request_id,
            status="success",
            vendor=request.vendor,
            txhash=request.txhash,
            vendor_response=vendor_response,
        )

    except HTTPException:
        raise
    except Exception as exc:
        duration = time.time() - start
        TRANSFER_LATENCY.labels(vendor=request.vendor).observe(duration)
        TRANSFER_REQUESTS.labels(vendor=request.vendor, status="error").inc()
        log.error("transfer_error", error=str(exc), exc_info=True)
        raise HTTPException(status_code=500, detail="Internal server error")
    finally:
        ACTIVE_TRANSFERS.dec()


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.detail, "status": "error"},
    )
