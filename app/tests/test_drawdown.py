"""Tests for drawdown — max_drawdown."""
from __future__ import annotations

import numpy as np
import pytest

from riskcheck.drawdown import max_drawdown


class TestMaxDrawdown:
    def test_known_drawdown(self):
        # Peak=110, trough=95 → DD = (95-110)/110 = -0.13636...
        values = np.array([100.0, 110.0, 105.0, 95.0, 100.0])
        mdd = max_drawdown(values)
        assert mdd == pytest.approx(-15.0 / 110.0, rel=1e-6)

    def test_monotonically_increasing_zero_dd(self):
        values = np.array([100.0, 101.0, 102.0, 103.0, 104.0])
        assert max_drawdown(values) == pytest.approx(0.0, abs=1e-10)

    def test_immediate_drop(self):
        values = np.array([200.0, 100.0])
        mdd = max_drawdown(values)
        assert mdd == pytest.approx(-0.50, rel=1e-6)

    def test_single_value_returns_zero(self):
        assert max_drawdown(np.array([100.0])) == 0.0

    def test_empty_array_returns_zero(self):
        assert max_drawdown(np.array([])) == 0.0

    def test_result_is_non_positive(self):
        rng = np.random.default_rng(7)
        values = np.cumprod(1.0 + rng.normal(0.001, 0.02, 100)) * 100_000
        assert max_drawdown(values) <= 0.0

    def test_recovery_does_not_affect_max_dd(self):
        # Deep dip then full recovery — MaxDD still captures the dip
        values = np.array([100.0, 150.0, 50.0, 150.0, 200.0])
        mdd = max_drawdown(values)
        assert mdd == pytest.approx(-100.0 / 150.0, rel=1e-6)
