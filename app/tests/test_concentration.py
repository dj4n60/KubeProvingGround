"""Tests for concentration — max_position_weight."""
from __future__ import annotations

import pytest

from riskcheck.concentration import max_position_weight
from riskcheck.models import Position


def _p(asset_id: str, weight: float) -> Position:
    return Position(asset_id=asset_id, weight=weight)


class TestMaxPositionWeight:
    def test_returns_max(self):
        positions = [_p("A", 0.30), _p("B", 0.15), _p("C", 0.10)]
        assert max_position_weight(positions) == pytest.approx(0.30)

    def test_single_position(self):
        assert max_position_weight([_p("A", 0.60)]) == pytest.approx(0.60)

    def test_empty_positions_zero(self):
        assert max_position_weight([]) == pytest.approx(0.0)

    def test_fractional_weights(self):
        positions = [_p("A", 0.249), _p("B", 0.251)]
        assert max_position_weight(positions) == pytest.approx(0.251)
