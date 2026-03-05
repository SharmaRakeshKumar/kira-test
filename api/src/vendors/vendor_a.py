import asyncio
from typing import Any, Dict
from ..services.base_vendor import BaseVendor


class VendorA(BaseVendor):
    """
    VendorA mock: immediate success.
    In production this would call VendorA's REST API
    using a key fetched from Vault/SSM.
    """

    async def process(
        self,
        amount: float,
        txhash: str,
        metadata: Dict[str, Any],
    ) -> Dict[str, Any]:
        # Simulate network call
        await asyncio.sleep(0.05)
        return {
            "status": "success",
            "vendor": "vendorA",
            "amount_cop": amount * 4200,  # mock FX rate
            "reference": f"VA-{txhash[-8:].upper()}",
        }
