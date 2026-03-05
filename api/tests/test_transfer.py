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


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as ac:
        yield ac


# ── Helper: mock blockchain ───────────────────────────────────────────────────
def mock_blockchain_confirmed(txhash: str):
    return respx.get(f"http://blockchain-mock:8001/tx/{txhash}").mock(
        return_value=httpx.Response(200, json={"txhash": txhash, "status": "confirmed"})
    )


def mock_blockchain_not_found(txhash: str):
    return respx.get(f"http://blockchain-mock:8001/tx/{txhash}").mock(
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
@respx.mock
async def test_transfer_vendor_a_success(client):
    """VendorA with confirmed txhash → status: success"""
    mock_blockchain_confirmed("0x123abc")
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": "0x123abc"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "success"
    assert data["vendor"] == "vendorA"
    assert data["vendor_response"]["status"] == "success"
    assert "request_id" in data


@pytest.mark.anyio
@respx.mock
async def test_transfer_vendor_b_pending(client):
    """VendorB with confirmed txhash → status: pending"""
    mock_blockchain_confirmed("0xdeadbeef")
    resp = await client.post(
        "/transfer",
        json={"amount": 50, "vendor": "vendorB", "txhash": "0xdeadbeef"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "success"
    assert data["vendor_response"]["status"] == "pending"


# ── POST /transfer: txhash failures ──────────────────────────────────────────
@pytest.mark.anyio
@respx.mock
async def test_transfer_invalid_txhash(client):
    """Unrecognised txhash → 422 not found"""
    mock_blockchain_not_found("invalidhash999")
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": "invalidhash999"},
    )
    # Pydantic rejects the format first
    assert resp.status_code == 422


@pytest.mark.anyio
@respx.mock
async def test_transfer_txhash_not_on_chain(client):
    """Valid format but blockchain returns not found → 422"""
    txhash = "0x" + "f" * 40
    mock_blockchain_not_found(txhash)
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": txhash},
    )
    assert resp.status_code == 422
    assert "not confirmed" in resp.json()["detail"]


# ── POST /transfer: vendor validation ────────────────────────────────────────
@pytest.mark.anyio
@respx.mock
async def test_transfer_unknown_vendor(client):
    """Unknown vendor → 400"""
    mock_blockchain_confirmed("0x123abc")
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorZ", "txhash": "0x123abc"},
    )
    assert resp.status_code == 400
    assert "Unknown vendor" in resp.json()["detail"]


# ── POST /transfer: input validation ─────────────────────────────────────────
@pytest.mark.anyio
async def test_transfer_negative_amount(client):
    resp = await client.post(
        "/transfer",
        json={"amount": -10, "vendor": "vendorA", "txhash": "0x123abc"},
    )
    assert resp.status_code == 422


@pytest.mark.anyio
async def test_transfer_zero_amount(client):
    resp = await client.post(
        "/transfer",
        json={"amount": 0, "vendor": "vendorA", "txhash": "0x123abc"},
    )
    assert resp.status_code == 422


@pytest.mark.anyio
async def test_transfer_missing_fields(client):
    resp = await client.post("/transfer", json={"amount": 100})
    assert resp.status_code == 422


# ── Metrics endpoint ──────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_metrics_endpoint(client):
    resp = await client.get("/metrics")
    assert resp.status_code == 200
    assert b"transfer_requests_total" in resp.content
