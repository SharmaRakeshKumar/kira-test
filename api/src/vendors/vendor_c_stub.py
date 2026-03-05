"""
VendorC — Example of adding a new vendor with zero system changes.

Steps to activate:
  1. Implement process() below
  2. In main.py add:
       from .vendors.vendor_c import VendorC
       vendor_registry.register("vendorC", VendorC())
  3. Add SECRET_VENDOR_C_KEY to config.py + Vault/SSM
  4. Deploy — no other infrastructure changes required.
"""

import asyncio
from typing import Any, Dict
from ..services.base_vendor import BaseVendor


class VendorC(BaseVendor):
    async def process(
        self,
        amount: float,
        txhash: str,
        metadata: Dict[str, Any],
    ) -> Dict[str, Any]:
        # TODO: implement real vendorC integration
        await asyncio.sleep(0.08)
        return {
            "status": "success",
            "vendor": "vendorC",
            "reference": f"VC-{txhash[-8:].upper()}",
        }
