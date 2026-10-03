"""Annualized portfolio volatility.

Scales sample standard deviation of daily returns to an annual figure
using the 252 trading-day convention.
"""
from __future__ import annotations

import numpy as np

_TRADING_DAYS = 252


def annualized_vol(returns: np.ndarray) -> float:
    """Annualized vol = sample std of daily returns × √252.

    Returns float('nan') when returns has fewer than 2 observations.
    """
    if len(returns) < 2:
        return float("nan")
    return float(np.std(returns, ddof=1) * np.sqrt(_TRADING_DAYS))
