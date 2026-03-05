import asyncio
from typing import Any, Dict
from ..services.base_vendor import BaseVendor


class VendorB(BaseVendor):
    """
    VendorB mock: async/pending flow.
    In production this would initiate an async transfer
    and provide a webhook callback URL.
    """

    async def process(
        self,
        amount: float,
        txhash: str,
        metadata: Dict[str, Any],
    ) -> Dict[str, Any]:
        await asyncio.sleep(0.1)
        return {
            "status": "pending",
            "vendor": "vendorB",
            "transfer_id": f"VB-{txhash[-8:].upper()}",
            "estimated_completion_minutes": 15,
            "callback_url": metadata.get("callback_url"),
        }
