"""Gate evaluation — collect all risk violations.

NEVER short-circuits: all violated gates accumulate in block_reasons[].
Operator contract: full diagnostic > fast rejection.

The Sharpe check only warns; it never blocks.
"""
from __future__ import annotations

import math

from riskcheck.models import Limits


def evaluate_gates(
    *,
    annualized_vol: float | None,
    max_dd: float | None,
    sharpe: float | None,
    max_weight: float | None,
    limits: Limits,
) -> tuple[list[str], list[str]]:
    """Evaluate all risk gates.

    Returns (block_reasons, warnings).
    None or NaN metric values indicate insufficient data → fail-closed.
    """
    block_reasons: list[str] = []
    warnings: list[str] = []

    def _bad(v: float | None) -> bool:
        return v is None or math.isnan(v)

    # ── Volatility gate ───────────────────────────────────────────────────────
    if _bad(annualized_vol):
        block_reasons.append("insufficient_history_for_vol")
    elif annualized_vol > limits.max_annualized_vol:  # type: ignore[operator]
        block_reasons.append("vol_too_high")

    # ── Max drawdown gate ─────────────────────────────────────────────────────
    if _bad(max_dd):
        block_reasons.append("insufficient_history_for_drawdown")
    elif max_dd < limits.max_drawdown:  # type: ignore[operator]
        block_reasons.append("drawdown_too_deep")

    # ── Sharpe check (warns only) ─────────────────────────────────────────────
    if limits.min_sharpe is not None and not _bad(sharpe):
        if sharpe < limits.min_sharpe:  # type: ignore[operator]
            warnings.append(f"sharpe_below_minimum: {sharpe:.4f} < {limits.min_sharpe}")

    # ── Concentration gate ────────────────────────────────────────────────────
    if _bad(max_weight):
        block_reasons.append("concentration_check_failed")
    elif max_weight > limits.max_position_weight:  # type: ignore[operator]
        block_reasons.append("concentration_too_high")

    return block_reasons, warnings
