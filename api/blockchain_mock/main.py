"""
Mock blockchain validation service.
Simulates an on-chain transaction lookup.

Rules:
  - txhash starting with "0x" and len >= 8  → "confirmed"
  - txhash == "0xpending"                   → "pending"
  - anything else                           → 404 not found
"""
from fastapi import FastAPI, HTTPException

app = FastAPI(title="Blockchain Mock Service")

CONFIRMED = {
    "0x123abc",
    "0xdeadbeef",
    "0x" + "a" * 64,
    "0x" + "b" * 64,
}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/tx/{txhash}")
def get_tx(txhash: str):
    if txhash == "0xpending":
        return {"txhash": txhash, "status": "pending", "confirmations": 1}

    # Deterministic mock: 0x-prefixed hashes with sufficient length are confirmed
    if txhash.startswith("0x") and len(txhash) >= 8:
        return {"txhash": txhash, "status": "confirmed", "confirmations": 12}

    raise HTTPException(status_code=404, detail="not found")
