"""Domain models for the autobuild runtime.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_models.py`
(see the KCC x Superpowers Hybrid Framework Plan 01, Task 1).

Serialization is deterministic (fixed field order, forbid extra fields,
validated assignment) so contract hashing of model instances is stable.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator


class StrictModel(BaseModel):
    """Base model with strict extra/assignment validation."""

    model_config = ConfigDict(extra="forbid", validate_assignment=True)


class LifecycleState(str, Enum):
    """States an autonomous build run moves through.

    Fail-closed transitions (enforced by the lifecycle service in later
    tasks) may only move forward when the current state matches the
    expected state.
    """

    INTAKE = "INTAKE"
    DISCOVERY = "DISCOVERY"
    PROTOTYPE_REVIEW = "PROTOTYPE_REVIEW"
    ARCHITECTURE = "ARCHITECTURE"
    DE_RISK = "DE_RISK"
    READINESS = "READINESS"
    CONTRACT_REVIEW = "CONTRACT_REVIEW"
    LOCKED = "LOCKED"
    BUILDING = "BUILDING"
    STAGING_VALIDATED = "STAGING_VALIDATED"
    DEPLOYED = "DEPLOYED"
    PRODUCTION_VALIDATED = "PRODUCTION_VALIDATED"
    DONE = "DONE"
    BLOCKED = "BLOCKED"
    EXTERNAL_WAIT = "EXTERNAL_WAIT"
    PAUSED = "PAUSED"
    HALTED = "HALTED"
    ROLLING_BACK = "ROLLING_BACK"
    RESUMING = "RESUMING"
    ABANDONED = "ABANDONED"


class FailureClass(str, Enum):
    """Classification of failures observed during an autobuild run."""

    AUTH = "AUTH"
    RATE = "RATE"
    OUTAGE = "OUTAGE"
    BUG = "BUG"
    DATA = "DATA"
    ENV = "ENV"
    CONTRACT = "CONTRACT"
    UNKNOWN = "UNKNOWN"


class DependencyStatus(str, Enum):
    """Status of a dependency required by an autobuild run."""

    USER_MUST_PROVIDE = "USER_MUST_PROVIDE"
    ALREADY_EXISTS = "ALREADY_EXISTS"
    AUTO_PROVISION_AUTHORIZED = "AUTO_PROVISION_AUTHORIZED"
    NOT_REQUIRED = "NOT_REQUIRED"


class ReadinessStatus(str, Enum):
    """Result of a readiness assessment for an autobuild run."""

    BLOCKER = "BLOCKER"
    RISK_MITIGATED = "RISK_MITIGATED"
    ACCEPTED_RISK = "ACCEPTED_RISK"
    READY = "READY"


class TaskStatus(str, Enum):
    """Execution status of a task within an autobuild run."""

    PENDING = "PENDING"
    RUNNING = "RUNNING"
    PASSED = "PASSED"
    FAILED = "FAILED"
    BLOCKED = "BLOCKED"


class RunRecord(StrictModel):
    """Metadata for one autonomous build run.

    ``created_at`` must be timezone-aware; naive datetimes are rejected
    so run timestamps are unambiguous when hashed or persisted.
    """

    run_id: str = Field(pattern=r"^RUN-[A-Za-z0-9][A-Za-z0-9-]*$")
    title: str
    created_at: datetime
    state: LifecycleState = LifecycleState.INTAKE
    contract_hash: str | None = None

    @field_validator("created_at")
    @classmethod
    def _created_at_must_be_aware(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("created_at must be timezone-aware")
        return value


class RunEvent(StrictModel):
    """An event emitted by/for a run.

    ``at`` must be timezone-aware so event ordering is unambiguous.
    """

    run_id: str
    kind: str
    at: datetime
    payload: dict[str, Any]

    @field_validator("at")
    @classmethod
    def _at_must_be_aware(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("at must be timezone-aware")
        return value
