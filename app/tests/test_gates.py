"""Tests for gates — evaluate_gates.

Key invariants:
- NEVER short-circuits: all violations must be collected.
- Sharpe check warns only.
- None/NaN → fail-closed block_reasons.
"""
from __future__ import annotations

from riskcheck.gates import evaluate_gates
from riskcheck.models import Limits

_LIMITS = Limits(
    min_history_days=20,
    max_annualized_vol=0.25,
    max_drawdown=-0.20,
    max_position_weight=0.25,
    min_sharpe=1.5,
)

_GOOD = dict(
    annualized_vol=0.15,
    max_dd=-0.10,
    sharpe=2.0,
    max_weight=0.20,
)


def _gates(**overrides):
    kwargs = {**_GOOD, **overrides}
    return evaluate_gates(limits=_LIMITS, **kwargs)


class TestNoViolations:
    def test_all_good(self):
        blocks, warnings = _gates()
        assert blocks == []
        assert warnings == []


class TestVolGate:
    def test_vol_too_high(self):
        blocks, _ = _gates(annualized_vol=0.30)
        assert "vol_too_high" in blocks

    def test_vol_at_limit_passes(self):
        blocks, _ = _gates(annualized_vol=0.25)
        assert blocks == []

    def test_vol_none_insufficient_history(self):
        blocks, _ = _gates(annualized_vol=None)
        assert "insufficient_history_for_vol" in blocks

    def test_vol_nan_insufficient_history(self):
        blocks, _ = _gates(annualized_vol=float("nan"))
        assert "insufficient_history_for_vol" in blocks


class TestDrawdownGate:
    def test_drawdown_too_deep(self):
        blocks, _ = _gates(max_dd=-0.30)
        assert "drawdown_too_deep" in blocks

    def test_drawdown_none_insufficient_history(self):
        blocks, _ = _gates(max_dd=None)
        assert "insufficient_history_for_drawdown" in blocks


class TestSharpeCheck:
    def test_low_sharpe_warns_never_blocks(self):
        blocks, warnings = _gates(sharpe=0.5)
        assert blocks == []
        assert len(warnings) == 1
        assert warnings[0].startswith("sharpe_below_minimum")

    def test_nan_sharpe_is_skipped(self):
        blocks, warnings = _gates(sharpe=float("nan"))
        assert blocks == []
        assert warnings == []

    def test_no_minimum_no_warning(self):
        blocks, warnings = evaluate_gates(limits=Limits(), **{**_GOOD, "sharpe": -3.0})
        assert blocks == []
        assert warnings == []


class TestConcentrationGate:
    def test_concentration_too_high(self):
        blocks, _ = _gates(max_weight=0.50)
        assert "concentration_too_high" in blocks

    def test_concentration_none_fails_closed(self):
        blocks, _ = _gates(max_weight=None)
        assert "concentration_check_failed" in blocks


class TestNoShortCircuit:
    def test_all_violations_collected(self):
        blocks, warnings = _gates(
            annualized_vol=0.90, max_dd=-0.80, sharpe=0.1, max_weight=0.99
        )
        assert blocks == ["vol_too_high", "drawdown_too_deep", "concentration_too_high"]
        assert len(warnings) == 1
