"""Annualized Sharpe ratio.

Excess returns are daily returns minus daily-equivalent risk-free rate.
Annualization uses the 252 trading-day convention.
Pure numpy — scipy.stats not needed for this computation.
"""
from __future__ import annotations

import numpy as np

_TRADING_DAYS = 252


def sharpe_ratio(returns: np.ndarray, annual_risk_free: float = 0.0) -> float:
    """Annualized Sharpe = mean(excess) / std(excess) × √252.

    Returns float('nan') when fewer than 2 observations or zero variance.
    """
    if len(returns) < 2:
        return float("nan")

    # Convert annual rate to daily equivalent (compound convention)
    daily_rf = (1.0 + annual_risk_free) ** (1.0 / _TRADING_DAYS) - 1.0
    excess = returns - daily_rf

    sigma = float(np.std(excess, ddof=1))

    # A degenerate (constant) series does NOT produce sigma == 0.0 exactly: float
    # accumulation in mean/std leaves ~1e-19 residue, and the exact comparison let
    # a flat series through as Sharpe ≈ 7e16, which passes any sharpe_target gate.
    # Compare against a scale-relative epsilon so degenerate input fails closed
    # (gates.py skips the Sharpe check on NaN instead of passing it).
    scale = float(np.max(np.abs(excess))) if excess.size else 0.0
    if sigma <= max(scale, 1.0) * 1e-12:
        return float("nan")

    return float(np.mean(excess) / sigma * np.sqrt(_TRADING_DAYS))
