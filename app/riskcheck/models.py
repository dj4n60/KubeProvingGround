"""Pydantic I/O schemas for the risk-check service.

List sizes are capped so one request cannot make the service allocate
unbounded memory.
"""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

MAX_VALUES = 5000
MAX_POSITIONS = 1000


class Position(BaseModel):
    """One holding and its share of the portfolio."""
    model_config = ConfigDict(extra="ignore")

    asset_id: str = Field(min_length=1, max_length=32)
    weight: float = Field(ge=0.0, le=1.0)


class Limits(BaseModel):
    """Gate thresholds — all optional, with defaults for an empty limits object."""
    model_config = ConfigDict(extra="ignore")

    min_history_days: int = Field(default=20, ge=2, le=MAX_VALUES - 1)
    max_annualized_vol: float = Field(default=0.40, gt=0.0)
    max_drawdown: float = Field(default=-0.35, le=0.0)
    max_position_weight: float = Field(default=0.40, gt=0.0, le=1.0)
    min_sharpe: float | None = None  # warning only, never blocks
    risk_free_rate: float = Field(default=0.0, ge=0.0, lt=1.0)


class AssessRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    values: list[float] = Field(max_length=MAX_VALUES)  # daily portfolio value, oldest first
    positions: list[Position] = Field(default_factory=list, max_length=MAX_POSITIONS)
    limits: Limits = Field(default_factory=Limits)


class Metrics(BaseModel):
    annualized_vol: float | None = None
    max_drawdown: float | None = None
    sharpe_ratio: float | None = None
    max_position_weight: float | None = None
    warnings: list[str] = Field(default_factory=list)


class AssessResponse(BaseModel):
    assessment_id: str
    approved: bool
    block_reasons: list[str]
    metrics: Metrics
    assessed_at: datetime
