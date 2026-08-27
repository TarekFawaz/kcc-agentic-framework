"""Behavioral tests for the autobuild runtime domain model layer.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.models`.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.models import (
    DependencyStatus,
    FailureClass,
    LifecycleState,
    ReadinessStatus,
    RunEvent,
    RunRecord,
    TaskStatus,
)


def test_lifecycle_state_contains_recovery_and_waiting_states() -> None:
    """LifecycleState must expose the recovery/waiting states."""
    for name in (
        "BLOCKED",
        "EXTERNAL_WAIT",
        "PAUSED",
        "HALTED",
        "ROLLING_BACK",
        "RESUMING",
    ):
        assert name in LifecycleState.__members__


def test_failure_class_values() -> None:
    """FailureClass values must be exactly the prescribed taxonomy."""
    assert [member.value for member in FailureClass] == [
        "AUTH",
        "RATE",
        "OUTAGE",
        "BUG",
        "DATA",
        "ENV",
        "CONTRACT",
        "UNKNOWN",
    ]


def test_dependency_status_values_pinned() -> None:
    """DependencyStatus values must be pinned in declaration order (Design Spec contract)."""
    assert [member.value for member in DependencyStatus] == [
        "USER_MUST_PROVIDE",
        "ALREADY_EXISTS",
        "AUTO_PROVISION_AUTHORIZED",
        "NOT_REQUIRED",
    ]


def test_readiness_status_values_pinned() -> None:
    """ReadinessStatus values must be pinned in declaration order (Design Spec contract)."""
    assert [member.value for member in ReadinessStatus] == [
        "BLOCKER",
        "RISK_MITIGATED",
        "ACCEPTED_RISK",
        "READY",
    ]


def test_task_status_values_pinned() -> None:
    """TaskStatus values must be pinned in declaration order (Design Spec contract)."""
    assert [member.value for member in TaskStatus] == [
        "PENDING",
        "RUNNING",
        "PASSED",
        "FAILED",
        "BLOCKED",
    ]


def test_run_event_rejects_naive_datetime() -> None:
    """RunEvent.at must be timezone-aware; naive datetimes are rejected."""
    with pytest.raises(ValidationError):
        RunEvent(
            run_id="RUN-001",
            kind="event",
            at=datetime(2026, 1, 1, 12, 0, 0),
            payload={},
        )


def test_run_record_defaults_state_to_intake() -> None:
    """RunRecord.state must default to LifecycleState.INTAKE."""
    record = RunRecord(
        run_id="RUN-001",
        title="TDD red/green run",
        created_at=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
    )
    assert record.state == LifecycleState.INTAKE
