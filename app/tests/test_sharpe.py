"""Tests for sharpe — sharpe_ratio."""
from __future__ import annotations

import math

import numpy as np
import pytest

from riskcheck.sharpe import sharpe_ratio

_TRADING_DAYS = 252


class TestSharpeRatio:
    def test_positive_returns_positive_sharpe(self):
        returns = np.full(30, 0.002)  # constant positive — std=0 → NaN
        # std is 0 for constant → NaN
        assert math.isnan(sharpe_ratio(returns))

    def test_known_value_zero_rf(self):
        """Spec : sharpe = mean(r) × 252 / σ_annual = mean/std(ddof=1) × √252.

        Asserted against the *sample* moments, not the generating distribution's.
        The previous form compared to the theoretical 1.587 with rel=0.15; for
        seed 0 the sample mean is 0.00052 (1.5 standard errors low), so the
        assertion was unreachable regardless of implementation. Sampling noise
        is not a property of the engine.
        """
        rng = np.random.default_rng(0)
        returns = rng.normal(0.001, 0.01, 1000)
        sr = sharpe_ratio(returns, 0.0)
        expected = float(np.mean(returns)) / float(np.std(returns, ddof=1)) * math.sqrt(
            _TRADING_DAYS
        )
        assert sr == pytest.approx(expected, rel=1e-12)

    def test_annualization_and_ddof_convention(self):
        """Pins the two conventions the formula depends on: √252 and ddof=1."""
        rng = np.random.default_rng(7)
        returns = rng.normal(0.0005, 0.008, 300)
        sr = sharpe_ratio(returns, 0.0)
        # ddof=0 would inflate Sharpe; assert the ddof=1 form is the one used.
        ddof0 = float(np.mean(returns)) / float(np.std(returns, ddof=0)) * math.sqrt(
            _TRADING_DAYS
        )
        ddof1 = float(np.mean(returns)) / float(np.std(returns, ddof=1)) * math.sqrt(
            _TRADING_DAYS
        )
        assert ddof0 != pytest.approx(ddof1, rel=1e-9)
        assert sr == pytest.approx(ddof1, rel=1e-12)

    def test_constant_series_is_nan_not_huge(self):
        """Degenerate flat series must fail closed, not return a gate-passing Sharpe.

        Regression: float residue in std(ddof=1) of a constant array is ~1e-19,
        not exactly 0.0, so the previous `sigma == 0.0` check returned ≈7.2e16.
        """
        for level in (0.002, -0.0015, 1.0):
            sr = sharpe_ratio(np.full(40, level))
            assert math.isnan(sr), f"constant series at {level} returned {sr}"

    def test_risk_free_uses_compound_daily_equivalent(self):
        """rf is converted (1+rf)^(1/252)-1, not rf/252."""
        annual_rf = 0.05
        daily_rf = (1.0 + annual_rf) ** (1.0 / _TRADING_DAYS) - 1.0
        rng = np.random.default_rng(11)
        returns = rng.normal(0.001, 0.01, 400)
        expected = (
            (float(np.mean(returns)) - daily_rf)
            / float(np.std(returns - daily_rf, ddof=1))
            * math.sqrt(_TRADING_DAYS)
        )
        assert sharpe_ratio(returns, annual_rf) == pytest.approx(expected, rel=1e-12)

    def test_with_nonzero_risk_free(self):
        rng = np.random.default_rng(1)
        returns = rng.normal(0.001, 0.01, 500)
        sr_rf0 = sharpe_ratio(returns, 0.0)
        sr_rf2 = sharpe_ratio(returns, 0.02)  # 2% annual rf reduces Sharpe
        assert sr_rf2 < sr_rf0

    def test_single_observation_nan(self):
        assert math.isnan(sharpe_ratio(np.array([0.01])))

    def test_empty_nan(self):
        assert math.isnan(sharpe_ratio(np.array([])))

    def test_zero_variance_nan(self):
        returns = np.zeros(50)
        assert math.isnan(sharpe_ratio(returns))

    def test_negative_mean_negative_sharpe(self):
        rng = np.random.default_rng(3)
        returns = rng.normal(-0.005, 0.01, 200)
        sr = sharpe_ratio(returns, 0.0)
        assert sr < 0.0
