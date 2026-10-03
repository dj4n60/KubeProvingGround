"""Maximum drawdown from portfolio value series.

MaxDD = min over t of (value_t - running_peak_t) / running_peak_t.
Result is a non-positive float (e.g. -0.25 for a 25% peak-to-trough loss).
"""
from __future__ import annotations

import numpy as np


def max_drawdown(values: np.ndarray) -> float:
    """Returns most-negative drawdown fraction; 0.0 when no drawdown exists.

    Requires at least 2 values. Returns 0.0 on shorter input.
    """
    if len(values) < 2:
        return 0.0
    running_peak = np.maximum.accumulate(values)
    drawdowns = (values - running_peak) / running_peak
    return float(np.min(drawdowns))
