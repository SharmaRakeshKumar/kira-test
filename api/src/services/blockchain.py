import httpx
import structlog
from ..config import settings

logger = structlog.get_logger()


class BlockchainService:
    """
    Validates that a txhash is confirmed on-chain.

    In production this would call a real blockchain node or indexer
    (e.g., Alchemy, QuickNode) over an internal network.
    """

    def __init__(self):
        self._client = httpx.AsyncClient(
            base_url=settings.BLOCKCHAIN_SERVICE_URL,
            timeout=settings.BLOCKCHAIN_TIMEOUT_SECONDS,
        )

    async def confirm(self, txhash: str) -> str:
        """
        Returns:
            "confirmed"  – tx found and has sufficient confirmations
            "pending"    – tx found but not yet finalized
            "not found"  – tx not found on-chain
        """
        log = logger.bind(txhash=txhash)
        try:
            resp = await self._client.get(f"/tx/{txhash}")
            resp.raise_for_status()
            data = resp.json()
            result = data.get("status", "not found")
            log.info("blockchain_response", result=result)
            return result
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 404:
                log.info("txhash_not_found")
                return "not found"
            log.error("blockchain_http_error", status=exc.response.status_code)
            raise
        except httpx.RequestError as exc:
            log.error("blockchain_connection_error", error=str(exc))
            raise
