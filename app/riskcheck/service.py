"""Top-level risk assessor.

assess(request) is the single entry point called by the FastAPI route.
It wires the metric pipeline:

    extract_returns       → value series + daily return array
    annualized_vol        → float | NaN
    max_drawdown          → float
    sharpe_ratio          → float | NaN
    max_position_weight   → float
    evaluate_gates        → (block_reasons[], warnings[])
"""
from __future__ import annotations

import logging
import math
import uuid
from datetime import UTC, datetime

import numpy as np

from riskcheck.concentration import max_position_weight
from riskcheck.drawdown import max_drawdown
from riskcheck.gates import evaluate_gates
from riskcheck.models import AssessRequest, AssessResponse, Metrics
from riskcheck.sharpe import sharpe_ratio
from riskcheck.volatility import annualized_vol

logger = logging.getLogger(__name__)


def extract_returns(
    values: list[float],
    min_days: int,
) -> tuple[np.ndarray | None, np.ndarray | None]:
    """Turn a daily value series into (values, returns) arrays.

    Returns (None, None) when history is too short or holds a value that is
    not a positive finite number.
    """
    if len(values) < min_days + 1:
        return None, None

    arr = np.asarray(values, dtype=np.float64)

    if not np.all(np.isfinite(arr)) or np.any(arr <= 0.0):
        return None, None

    return arr, np.diff(arr) / arr[:-1]


def assess(request: AssessRequest) -> AssessResponse:
    """Compute portfolio risk metrics and emit binary approval with diagnostics."""
    assessment_id = str(uuid.uuid4())
    limits = request.limits

    values, returns = extract_returns(request.values, limits.min_history_days)

    # Time-series metrics stay None when history is insufficient.
    if values is not None and returns is not None:
        vol = annualized_vol(returns)
        mdd = max_drawdown(values)
        sharpe = sharpe_ratio(returns, limits.risk_free_rate)
    else:
        vol = mdd = sharpe = None

    max_w = max_position_weight(request.positions)

    block_reasons, warnings = evaluate_gates(
        annualized_vol=vol,
        max_dd=mdd,
        sharpe=sharpe,
        max_weight=max_w,
        limits=limits,
    )

    approved = len(block_reasons) == 0

    logger.info(
        "assess | id=%s approved=%s blocks=%s",
        assessment_id,
        approved,
        block_reasons or "none",
    )

    return AssessResponse(
        assessment_id=assessment_id,
        approved=approved,
        block_reasons=block_reasons,
        metrics=Metrics(
            # _safe() strips NaN → None. A bare NaN is not valid JSON.
            annualized_vol=_safe(vol),
            max_drawdown=_safe(mdd),
            sharpe_ratio=_safe(sharpe),
            max_position_weight=_safe(max_w),
            warnings=warnings,
        ),
        assessed_at=datetime.now(UTC),
    )


def _safe(v: float | None) -> float | None:
    if v is None:
        return None
    return None if math.isnan(v) else v
