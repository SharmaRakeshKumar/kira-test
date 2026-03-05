from abc import ABC, abstractmethod
from typing import Any, Dict


class BaseVendor(ABC):
    """
    Abstract base for all off-ramp vendor integrations.

    To add a new vendor:
      1. Subclass BaseVendor
      2. Implement `process()`
      3. Register in main.py via vendor_registry.register()
    """

    @abstractmethod
    async def process(
        self,
        amount: float,
        txhash: str,
        metadata: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Send the off-ramp request to the vendor.

        Returns a dict with at minimum {"status": "<vendor_status>"}.
        """
        ...

    @property
    def name(self) -> str:
        return self.__class__.__name__
