"""
Test suite for the USDC → COP Payments API.
"""
import pytest
import httpx
from httpx import AsyncClient, ASGITransport

import os
os.environ.setdefault("BLOCKCHAIN_SERVICE_URL", "http://blockchain-mock:8001")

from src.main import app, blockchain_service

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
    Returns an httpx AsyncClient with a MockTransport.
    Injects directly into the blockchain_service instance.
    """
    def handler(request: httpx.Request) -> httpx.Response:
        txhash = request.url.path.split("/tx/")[-1]
        if txhash in responses:
            status, body = responses[txhash]
            return httpx.Response(status, json=body)
        return httpx.Response(404, json={"detail": "not found"})

    return httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        base_url="http://blockchain-mock:8001",
    )


@pytest.fixture(autouse=True)
def reset_blockchain_client():
    """Save and restore the real blockchain client after every test."""
    original = blockchain_service._client   # instance attribute — always exists
    yield
    blockchain_service._client = original


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
    blockchain_service._client = _make_blockchain_mock({
        VALID_TX_A: (200, {"txhash": VALID_TX_A, "status": "confirmed"})
    })
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
    blockchain_service._client = _make_blockchain_mock({
        VALID_TX_B: (200, {"txhash": VALID_TX_B, "status": "confirmed"})
    })
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
    blockchain_service._client = _make_blockchain_mock({})  # empty → all 404
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": VALID_TX_LONG},
    )
    assert resp.status_code == 422

async def test_transfer_txhash_blockchain_not_found_sentinel(client):
    """0xdeaddead passes format validation but blockchain returns 404 → 422"""
    NOT_FOUND_TX = "0xdeaddead"
    blockchain_service._client = _make_blockchain_mock({
        NOT_FOUND_TX: (404, {"detail": "not found"})
    })
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorA", "txhash": NOT_FOUND_TX},
    )
    assert resp.status_code == 422


# ── POST /transfer: vendor validation ────────────────────────────────────────
async def test_transfer_unknown_vendor(client):
    """Unknown vendor → 400"""
    blockchain_service._client = _make_blockchain_mock({
        VALID_TX_A: (200, {"txhash": VALID_TX_A, "status": "confirmed"})
    })
    resp = await client.post(
        "/transfer",
        json={"amount": 100, "vendor": "vendorZ", "txhash": VALID_TX_A},
    )
    assert resp.status_code == 400

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