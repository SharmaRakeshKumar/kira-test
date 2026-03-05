"""
Test suite for the USDC → COP Payments API.
"""
import pytest
import httpx
from httpx import AsyncClient, ASGITransport

import os
os.environ.setdefault("BLOCKCHAIN_SERVICE_URL", "http://blockchain-mock:8001")

from src.main import app
from src.services.blockchain import BlockchainService

VALID_TX_A    = "0x123abc"
VALID_TX_B    = "0xdeadbeef"
VALID_TX_LONG = "0x" + "f" * 40


@pytest.fixture
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as ac:
        yield ac


def _make_blockchain_mock(responses: dict):
    """
    Returns an httpx MockTransport that serves predefined txhash responses.
    Bypasses respx entirely — injects a fake transport directly into
    BlockchainService so no timing or scope issues are possible.
    """
    def handler(request: httpx.Request) -> httpx.Response:
        txhash = request.url.path.split("/tx/")[-1]
        if txhash in responses:
            status, body = responses[txhash]
            return httpx.Response(status, json=body)
        return httpx.Response(404, json={"detail": "not found"})

    return httpx.MockTransport(handler)


@pytest.fixture(autouse=True)
def reset_blockchain_client():
    """Restore the real blockchain client after every test."""
    original = BlockchainService._client
    yield
    BlockchainService._client = original


# ── Health checks ─────────────────────────────────────────────────────────────
async def test_health(client):
    resp = await client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


async def test_ready(client):
    resp = await client.get("/ready")
    assert resp.status_code == 200
    data = resp.json()
    assert "vendorA" in data["vendors"]
    assert "vendorB" in data["vendors"]


# ── POST /transfer: happy paths ───────────────────────────────────────────────
async def test_transfer_vendor_a_success(client):
    """VendorA with confirmed txhash → status: success"""
    from src.main import blockchain_service
    blockchain_service._client = httpx.AsyncClient(
        transport=_make_blockchain_mock({
            VALID_TX_A: (200, {"txhash": VALID_TX_A, "status": "confirmed"})
        }),
        base_url="http://blockchain-mock:8001",
    )
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


async def test_transfer_vendor_b_pending(client):
    """VendorB with confirmed txhash → vendor_response.status: pending"""
    from src.main import blockchain_service
    blockchain_service._client = httpx.AsyncClient(
        transport=_make_blockchain_mock({
            VALID_TX_B: (200, {"txhash": VALID_TX_B, "status": "confirmed"})
        }),
        base_url="http://blockchain-mock:8001",
    )
    resp = await client.post(
        "/transfer",
        json={"amount": 50, "vendor": "vendorB", "txhash": VALID_TX_B},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "success"
    assert data["vendor_response"]["status"] == "pending"


# ── POST /transfer: txhash failures ──────────────────────────────────────────
async def test_transfer_invalid_txhash(client):
    """Badly formatted txhash → Pydantic rejects with 422"""
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": "not-a-hash"},
    )
    assert resp.status_code == 422


async def test_transfer_txhash_not_on_chain(client):
    """Valid format but blockchain returns 404 → 422"""
    from src.main import blockchain_service
    blockchain_service._client = httpx.AsyncClient(
        transport=_make_blockchain_mock({}),  # empty → all return 404
        base_url="http://blockchain-mock:8001",
    )
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": VALID_TX_LONG},
    )
    assert resp.status_code == 422
    assert "not confirmed" in resp.json()["detail"]


# ── POST /transfer: vendor validation ────────────────────────────────────────
async def test_transfer_unknown_vendor(client):
    """Unknown vendor → 400"""
    from src.main import blockchain_service
    blockchain_service._client = httpx.AsyncClient(
        transport=_make_blockchain_mock({
            VALID_TX_A: (200, {"txhash": VALID_TX_A, "status": "confirmed"})
        }),
        base_url="http://blockchain-mock:8001",
    )
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorZ", "txhash": VALID_TX_A},
    )
    assert resp.status_code == 400
    assert "Unknown vendor" in resp.json()["detail"]


# ── Input validation ──────────────────────────────────────────────────────────
async def test_transfer_negative_amount(client):
    resp = await client.post(
        "/transfer",
        json={"amount": -10, "vendor": "vendorA", "txhash": VALID_TX_A},
    )
    assert resp.status_code == 422


async def test_transfer_zero_amount(client):
    resp = await client.post(
        "/transfer",
        json={"amount": 0, "vendor": "vendorA", "txhash": VALID_TX_A},
    )
    assert resp.status_code == 422


async def test_transfer_missing_fields(client):
    resp = await client.post("/transfer", json={"amount": 100})
    assert resp.status_code == 422


# ── Metrics endpoint ──────────────────────────────────────────────────────────
async def test_metrics_endpoint(client):
    resp = await client.get("/metrics/", follow_redirects=True)
    assert resp.status_code == 200
    assert b"transfer_requests_total" in resp.content