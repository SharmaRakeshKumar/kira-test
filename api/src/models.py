from typing import Any, Dict, Optional
from pydantic import BaseModel, field_validator
import re


class TransferRequest(BaseModel):
    amount: float
    vendor: str
    txhash: str
    metadata: Optional[Dict[str, Any]] = None

    @field_validator("amount")
    @classmethod
    def amount_must_be_positive(cls, v):
        if v <= 0:
            raise ValueError("amount must be positive")
        return v

    @field_validator("txhash")
    @classmethod
    def txhash_format(cls, v):
        # Accept 0x-prefixed hex (EVM) or any 32+ char alphanumeric hash
        if not re.match(r"^(0x[a-fA-F0-9]{40,}|[a-fA-F0-9]{32,})$", v):
            raise ValueError("txhash must be a valid transaction hash")
        return v

    @field_validator("vendor")
    @classmethod
    def vendor_alphanumeric(cls, v):
        if not re.match(r"^[a-zA-Z0-9_-]+$", v):
            raise ValueError("vendor name must be alphanumeric")
        return v


class TransferResponse(BaseModel):
    request_id: str
    status: str
    vendor: str
    txhash: str
    vendor_response: Dict[str, Any]
