# ── Stage 1: dependency builder ─────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build
RUN python -m venv /venv
COPY requirements.txt .
RUN /venv/bin/pip install --no-cache-dir -r requirements.txt

# ── Stage 2: lean runtime image ─────────────────────────────────────────────
FROM python:3.12-slim AS runtime

WORKDIR /app

# SOC 2: run as non-root
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Copy only the venv — no pip cache, no build tools in final image
COPY --from=builder /venv /venv

COPY --chown=appuser:appuser . .

USER appuser

ENV PATH="/venv/bin:$PATH"

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import httpx; httpx.get('http://localhost:8000/health').raise_for_status()"

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
