"""
Mock blockchain validation service.
Simulates an on-chain transaction lookup.

Rules:
  - txhash == "0xpending"                   → "pending"
  - txhash == "0xdeaddead"                  → 404 not found  (test sentinel)
  - txhash 0x-prefixed len >= 8             → "confirmed"
  - anything else                           → 404 not found
"""
from fastapi import FastAPI, HTTPException

app = FastAPI(title="Blockchain Mock Service")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/tx/{txhash}")
def get_tx(txhash: str):
    if txhash == "0xpending":
        return {"txhash": txhash, "status": "pending", "confirmations": 1}

    # Sentinel: valid hex format but explicitly not found — used in tests
    if txhash == "0xdeaddead":
        raise HTTPException(status_code=404, detail="not found")

    # Deterministic mock: 0x-prefixed hashes with sufficient length are confirmed
    if txhash.startswith("0x") and len(txhash) >= 8:
        return {"txhash": txhash, "status": "confirmed", "confirmations": 12}

    raise HTTPException(status_code=404, detail="not found")
