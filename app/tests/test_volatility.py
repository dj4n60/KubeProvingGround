"""Tests for volatility — annualized_vol."""
from __future__ import annotations

import math

import numpy as np
import pytest

from riskcheck.volatility import annualized_vol

_TRADING_DAYS = 252


class TestAnnualizedVol:
    def test_known_value(self):
        # σ_daily = 0.01 → annualized = 0.01 * sqrt(252)
        returns = np.full(30, 0.0)
        returns[0] = 0.01
        returns[1] = -0.01
        # std of [0.01, -0.01, 0, 0, ...] ≈ non-zero
        vol = annualized_vol(returns)
        assert vol >= 0.0
        assert math.isfinite(vol)

    def test_constant_returns_zero_vol(self):
        returns = np.full(50, 0.005)
        vol = annualized_vol(returns)
        assert vol == pytest.approx(0.0, abs=1e-10)

    def test_scaling_factor(self):
        sigma_daily = 0.01
        returns = np.random.default_rng(0).normal(0, sigma_daily, 1000)
        vol = annualized_vol(returns)
        expected = sigma_daily * math.sqrt(_TRADING_DAYS)
        assert vol == pytest.approx(expected, rel=0.10)  # within 10% of theoretical

    def test_single_return_is_nan(self):
        returns = np.array([0.01])
        assert math.isnan(annualized_vol(returns))

    def test_empty_returns_is_nan(self):
        assert math.isnan(annualized_vol(np.array([])))

    def test_output_is_positive_for_noisy_returns(self):
        rng = np.random.default_rng(42)
        returns = rng.normal(0.001, 0.015, 60)
        vol = annualized_vol(returns)
        assert vol > 0.0
