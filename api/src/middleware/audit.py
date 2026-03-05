import time
import structlog
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

logger = structlog.get_logger()


class AuditMiddleware(BaseHTTPMiddleware):
    """
    SOC 2 audit trail: logs every inbound request with method, path,
    status code, latency, and client IP. Sensitive fields (txhash) are
    logged for auditability — in production, ship logs to an immutable
    append-only store (CloudWatch Logs, Loki with object storage).
    """

    SENSITIVE_PATHS = {"/transfer"}

    async def dispatch(self, request: Request, call_next):
        start = time.time()
        client_ip = request.headers.get("X-Forwarded-For", request.client.host if request.client else "unknown")

        response = await call_next(request)

        duration = time.time() - start
        log = logger.bind(
            event="http_request",
            method=request.method,
            path=request.url.path,
            status_code=response.status_code,
            latency_ms=round(duration * 1000, 2),
            client_ip=client_ip,
            user_agent=request.headers.get("user-agent", ""),
        )

        if response.status_code >= 500:
            log.error("request_error")
        elif response.status_code >= 400:
            log.warning("request_client_error")
        else:
            log.info("request_ok")

        return response
