from __future__ import annotations

import logging
import time
from datetime import UTC, datetime

from fastapi import FastAPI

from riskcheck import __version__
from riskcheck.models import AssessRequest, AssessResponse
from riskcheck.service import assess

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)

_START_MONOTONIC = time.monotonic()
_START_WALL = datetime.now(UTC)

app = FastAPI(
    title="risk-check",
    version=__version__,
    description="Portfolio risk gate: volatility, max drawdown, Sharpe and concentration",
)


# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/health", tags=["ops"])
def health() -> dict:
    """Liveness and readiness probe — the service holds no state and has no dependencies."""
    return {
        "status": "ok",
        "version": __version__,
        "uptime_seconds": round(time.monotonic() - _START_MONOTONIC, 1),
        "started_at": _START_WALL.isoformat(),
    }


# ── Info ──────────────────────────────────────────────────────────────────────

@app.get("/info", tags=["ops"])
def info() -> dict:
    """Service metadata: version and available endpoints."""
    return {
        "service": "risk-check",
        "version": __version__,
        "endpoints": [
            {"method": "POST", "path": "/assess", "description": "Risk metrics → approved/blocked"},
            {"method": "GET",  "path": "/health", "description": "Liveness and readiness probe"},
            {"method": "GET",  "path": "/info",   "description": "Service metadata"},
        ],
    }


# ── Assess ────────────────────────────────────────────────────────────────────

@app.post("/assess", response_model=AssessResponse, tags=["risk"])
def assess_portfolio(request: AssessRequest) -> AssessResponse:
    """Always 200 on a valid body: approved=false carries block_reasons[]. 422 on a bad schema."""
    return assess(request)
