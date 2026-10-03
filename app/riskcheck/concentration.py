"""Portfolio concentration — maximum single-position weight."""
from __future__ import annotations

from riskcheck.models import Position


def max_position_weight(positions: list[Position]) -> float:
    """Returns the largest weight across all positions.

    Returns 0.0 for an empty list (no position → no concentration).
    """
    if not positions:
        return 0.0
    return max(float(p.weight) for p in positions)
