"""
Test suite for the USDC → COP Payments API.
Runs as unit tests (no live services needed) and as
post-deployment smoke tests (against a live stack).
"""
import pytest
import respx
import httpx
from httpx import AsyncClient, ASGITransport

# ── Test setup ────────────────────────────────────────────────────────────────
import os
os.environ.setdefault("BLOCKCHAIN_SERVICE_URL", "http://blockchain-mock:8001")

from src.main import app

# Valid txhashes that pass the Pydantic validator (0x + at least 6 hex chars)
VALID_TX_A    = "0x123abc"
VALID_TX_B    = "0xdeadbeef"
VALID_TX_LONG = "0x" + "f" * 40   # used for not-on-chain test

BLOCKCHAIN_BASE = "http://blockchain-mock:8001"


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as ac:
        yield ac


# ── Blockchain mock helpers ───────────────────────────────────────────────────
def _confirmed(router, txhash: str):
    router.get(f"{BLOCKCHAIN_BASE}/tx/{txhash}").mock(
        return_value=httpx.Response(200, json={"txhash": txhash, "status": "confirmed"})
    )

def _not_found(router, txhash: str):
    router.get(f"{BLOCKCHAIN_BASE}/tx/{txhash}").mock(
        return_value=httpx.Response(404, json={"detail": "not found"})
    )


# ── Health checks ─────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_health(client):
    resp = await client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


@pytest.mark.anyio
async def test_ready(client):
    resp = await client.get("/ready")
    assert resp.status_code == 200
    data = resp.json()
    assert "vendorA" in data["vendors"]
    assert "vendorB" in data["vendors"]


# ── POST /transfer: happy paths ───────────────────────────────────────────────
@pytest.mark.anyio
async def test_transfer_vendor_a_success(client):
    """VendorA with confirmed txhash → status: success"""
    with respx.mock(base_url=BLOCKCHAIN_BASE) as router:
        _confirmed(router, VALID_TX_A)
        resp = await client.post(
            "/transfer",
            json={"amount": 100, "vendor": "vendorA", "txhash": VALID_TX_A},
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "success"
    assert data["vendor"] == "vendorA"
    assert data["vendor_response"]["status"] == "success"
    assert "request_id" in data


@pytest.mark.anyio
async def test_transfer_vendor_b_pending(client):
    """VendorB with confirmed txhash → vendor_response.status: pending"""
    with respx.mock(base_url=BLOCKCHAIN_BASE) as router:
        _confirmed(router, VALID_TX_B)
        resp = await client.post(
            "/transfer",
            json={"amount": 50, "vendor": "vendorB", "txhash": VALID_TX_B},
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "success"
    assert data["vendor_response"]["status"] == "pending"


# ── POST /transfer: txhash failures ──────────────────────────────────────────
@pytest.mark.anyio
async def test_transfer_invalid_txhash(client):
    """Badly formatted txhash → Pydantic rejects with 422 before hitting blockchain"""
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": "not-a-hash"},
    )
    assert resp.status_code == 422


@pytest.mark.anyio
async def test_transfer_txhash_not_on_chain(client):
    """Valid format but blockchain returns 404 → 422 not confirmed"""
    with respx.mock(base_url=BLOCKCHAIN_BASE) as router:
        _not_found(router, VALID_TX_LONG)
        resp = await client.post(
            "/transfer",
            json={"amount": 100, "vendor": "vendorA", "txhash": VALID_TX_LONG},
        )
    assert resp.status_code == 422
    assert "not confirmed" in resp.json()["detail"]


# ── POST /transfer: vendor validation ────────────────────────────────────────
@pytest.mark.anyio
async def test_transfer_unknown_vendor(client):
    """Unknown vendor → 400 after blockchain confirms txhash"""
    with respx.mock(base_url=BLOCKCHAIN_BASE) as router:
        _confirmed(router, VALID_TX_A)
        resp = await client.post(
            "/transfer",
            json={"amount": 100, "vendor": "vendorZ", "txhash": VALID_TX_A},
        )
    assert resp.status_code == 400
    assert "Unknown vendor" in resp.json()["detail"]


# ── POST /transfer: input validation ─────────────────────────────────────────
@pytest.mark.anyio
async def test_transfer_negative_amount(client):
    resp = await client.post(
        "/transfer",
        json={"amount": -10, "vendor": "vendorA", "txhash": VALID_TX_A},
    )
    assert resp.status_code == 422


@pytest.mark.anyio
async def test_transfer_zero_amount(client):
    resp = await client.post(
        "/transfer",
        json={"amount": 0, "vendor": "vendorA", "txhash": VALID_TX_A},
    )
    assert resp.status_code == 422


@pytest.mark.anyio
async def test_transfer_missing_fields(client):
    resp = await client.post("/transfer", json={"amount": 100})
    assert resp.status_code == 422


# ── Metrics endpoint ──────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_metrics_endpoint(client):
    # /metrics/ with trailing slash avoids the 307 redirect from the ASGI mount
    resp = await client.get("/metrics/", follow_redirects=True)
    assert resp.status_code == 200
    assert b"transfer_requests_total" in resp.content