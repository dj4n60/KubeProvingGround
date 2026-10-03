"""HTTP-level tests: routes, schema validation and the approve/block contract."""
from __future__ import annotations

import numpy as np
import pytest
from fastapi.testclient import TestClient

from riskcheck.main import app

_client = TestClient(app)


def make_values(n: int = 60, seed: int = 42, mu: float = 0.0003, sigma: float = 0.006) -> list[float]:
    """Produce n days of synthetic portfolio values with N(mu, sigma) returns."""
    rng = np.random.default_rng(seed)
    values = [100_000.0]
    for r in rng.normal(mu, sigma, n - 1):
        values.append(values[-1] * (1.0 + r))
    return values


_BALANCED = [
    {"asset_id": "AAA", "weight": 0.30},
    {"asset_id": "BBB", "weight": 0.30},
    {"asset_id": "CCC", "weight": 0.25},
    {"asset_id": "DDD", "weight": 0.15},
]


class TestOpsRoutes:
    def test_health(self):
        resp = _client.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_info_lists_assess(self):
        resp = _client.get("/info")
        assert resp.status_code == 200
        assert any(e["path"] == "/assess" for e in resp.json()["endpoints"])


class TestAssess:
    def test_calm_balanced_portfolio_approved(self):
        resp = _client.post("/assess", json={"values": make_values(), "positions": _BALANCED})
        assert resp.status_code == 200
        body = resp.json()
        assert body["approved"] is True
        assert body["block_reasons"] == []
        assert body["metrics"]["annualized_vol"] > 0.0
        assert body["metrics"]["max_position_weight"] == pytest.approx(0.30)
        assert len(body["assessment_id"]) > 0

    def test_short_history_fails_closed(self):
        resp = _client.post("/assess", json={"values": make_values(n=5), "positions": _BALANCED})
        body = resp.json()
        assert resp.status_code == 200
        assert body["approved"] is False
        assert "insufficient_history_for_vol" in body["block_reasons"]
        assert "insufficient_history_for_drawdown" in body["block_reasons"]
        assert body["metrics"]["annualized_vol"] is None

    def test_non_positive_value_fails_closed(self):
        values = make_values()
        values[10] = 0.0
        body = _client.post("/assess", json={"values": values, "positions": _BALANCED}).json()
        assert body["approved"] is False
        assert "insufficient_history_for_vol" in body["block_reasons"]

    def test_volatile_portfolio_blocked(self):
        resp = _client.post(
            "/assess",
            json={"values": make_values(sigma=0.05), "positions": _BALANCED},
        )
        assert "vol_too_high" in resp.json()["block_reasons"]

    def test_concentrated_portfolio_blocked(self):
        positions = [{"asset_id": "AAA", "weight": 0.80}, {"asset_id": "BBB", "weight": 0.20}]
        body = _client.post("/assess", json={"values": make_values(), "positions": positions}).json()
        assert body["block_reasons"] == ["concentration_too_high"]

    def test_custom_limits_applied(self):
        body = _client.post(
            "/assess",
            json={
                "values": make_values(),
                "positions": _BALANCED,
                "limits": {"max_position_weight": 0.20},
            },
        ).json()
        assert body["block_reasons"] == ["concentration_too_high"]

    def test_string_encoded_numbers_coerced(self):
        values = [str(v) for v in make_values()]
        positions = [{"asset_id": "AAA", "weight": "0.30"}]
        resp = _client.post("/assess", json={"values": values, "positions": positions})
        assert resp.status_code == 200
        assert resp.json()["approved"] is True


class TestValidation:
    def test_missing_values_is_422(self):
        assert _client.post("/assess", json={"positions": _BALANCED}).status_code == 422

    def test_weight_above_one_is_422(self):
        resp = _client.post(
            "/assess",
            json={"values": make_values(), "positions": [{"asset_id": "AAA", "weight": 1.5}]},
        )
        assert resp.status_code == 422

    def test_oversized_history_is_422(self):
        resp = _client.post("/assess", json={"values": [100.0] * 5001})
        assert resp.status_code == 422
