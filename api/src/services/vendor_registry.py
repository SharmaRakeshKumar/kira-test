from typing import Dict, List, Optional
from .base_vendor import BaseVendor


class VendorRegistry:
    """
    Central registry for vendor integrations.

    Adding a new vendor (e.g., vendorC) requires only:
      1. Create api/src/vendors/vendor_c.py implementing BaseVendor
      2. vendor_registry.register("vendorC", VendorC())

    No other code changes needed.
    """

    def __init__(self):
        self._vendors: Dict[str, BaseVendor] = {}

    def register(self, name: str, vendor: BaseVendor) -> None:
        self._vendors[name] = vendor

    def get(self, name: str) -> Optional[BaseVendor]:
        return self._vendors.get(name)

    def list_vendors(self) -> List[str]:
        return list(self._vendors.keys())
