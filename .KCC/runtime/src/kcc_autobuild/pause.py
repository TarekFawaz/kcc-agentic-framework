"""PAUSED drain / fence / resource-freeze semantics and light resume.

Plan 05, Task 6 (PAUSED drain / fence / resource-freeze semantics): a
pause is a *cooperative, checkpointed* stop, not a kill. Spec 22 makes
durable state authoritative (conversation memory is never the source of
truth for progress), spec 14.5 classifies destructive/mutating operations
before execution, and the plan Global Constraints require the controller
to reserve money/rate exactly once -- so a pause must never release the
bookings it will need on resume, and a resume must never re-reserve.

The behavioral contract is owned by :file:`.KCC/runtime/tests/test_pause.py`:

- :func:`pause` (via :class:`PauseCoordinator.pause`) stops new dispatch
  (the durable ``PAUSED`` transition is persisted FIRST), signals every
  running worker to check out, and drains it:
  * a **noninterruptible operation** (e.g. an in-flight rollback) is
    NEVER fenced while it runs -- the drain waits for it to reach its
    **stable boundary**;
  * a worker that is not at a stable boundary when the drain deadline
    arrives is a hung worker and **is fenced** (its lease is revoked, so
    it can never report against the paused run);
  * every drained attempt's **task time budget is frozen** (the elapsed
    time is consumed, the clock stops);
  * the **resume reservation is retained by default** -- money/rate are
    NOT released -- the only exception being a time budget exhausted at
    the boundary (the task is terminal then, and a retained booking for
    a terminal task would leak);
  * **reversible resources are frozen only when the locked Tier-1
    destructive policy classifies them reversible** (optional, fail
    closed without a freezer);
  * the **paused checkpoint is persisted** (``run.paused`` event) and the
    run is in ``PAUSED``.
- :func:`resume` (via :class:`PauseCoordinator.resume`) is a **light**
  revalidation -- never a full discovery -- that checks, in order:
  the **locked Tier-1 hash** (the contract is still locked, its canonical
  hash is still self-consistent, and it still matches the hash recorded
  in the paused checkpoint), the **credential/evidence freshness needed
  for the next tasks** (fresh pass evidence for the providers the resumed
  tasks need, from the packed readiness evidence -- no probes), **provider
  availability** and the **target-state markers** of those tasks (both
  through the injected light probe). Then it **rebalances the
  reservation** (a retained booking that no longer belongs to a resumed
  task is released; a resumed task whose retained booking vanished while
  paused is a broken ledger and fails closed -- never a silent
  re-reserve), **mints a fresh lease generation** per resumed task,
  **unfreezes the time budget** (the same clock continues), unfreezes any
  resources frozen at pause, **enables dispatch** (``PAUSED -> RESUMING ->
  BUILDING``) and **persists the resume event** => ``BUILDING``.
  Revalidation failure is fail-closed: the run stays ``PAUSED``, no lease
  is minted, no clock is unfrozen, and the batched
  :class:`ResumeRevalidationError` carries the findings (persisted as
  ``run.resume_rejected``).

All timestamps are timezone-aware UTC (R7 discipline). ``now`` defaults to
the wall clock when a caller does not hand one in (the tests always hand
in a deterministic instant); identical input always yields identical
output (the drain polls on a fixed interval, the task sets are sorted).
Two additional fail-closed paths are guaranteed:

- a **drain adapter failure mid-``pause``** never strands the run ``PAUSED``
  without a checkpoint: the durable ``PAUSED`` transition happened first,
  so the still-unresolved workers are fenced as hung at the pause instant,
  the best-effort checkpoint is persisted, and
  :class:`PauseDrainAdapterError` (carrying that checkpoint) is raised;
- ``resume`` wraps the **whole mutation phase** (rebalance, resource
  restore, lease mint, clock start, dispatch transitions) in one guarded
  block: on any failure the minted leases are fenced, the started clocks
  are refrozen and the restored resources are re-frozen, ``run.resume_
  failed`` is persisted with the cleanup report, and
  :class:`ResumeMutationError` is raised -- the run stays ``PAUSED`` and a
  later resume retries from a clean ledger instead of wedging on an
  abandoned live lease.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from enum import Enum
from typing import Iterable, Mapping, Protocol, Sequence, runtime_checkable

from pydantic import ValidationInfo, computed_field, field_validator, model_validator

from kcc_autobuild.budget import BudgetLedger
from kcc_autobuild.contract import (
    CONTRACT_HASH_PATTERN,
    BuildContract,
    DestructiveAction,
    tier1_canonical_hash,
)
from kcc_autobuild.leases import Lease, LeaseLedger, LeaseStore
from kcc_autobuild.models import RUN_ID_PATTERN, LifecycleState, RunEvent, StrictModel
from kcc_autobuild.rate_limit import RateCapacityLedger, RateDemand
from kcc_autobuild.readiness import ReadinessPack, evaluate_readiness
from kcc_autobuild.store import RunStore

DEFAULT_DRAIN_TIMEOUT = timedelta(seconds=300)
"""Default deadline for the pause checkpoint drain."""

DEFAULT_POLL_INTERVAL = timedelta(seconds=5)
"""Default interval between drain polls (deterministic tick advance)."""

_PAUSABLE_STATES = frozenset(
    {
        LifecycleState.BUILDING,
        LifecycleState.STAGING_VALIDATED,
        LifecycleState.ROLLING_BACK,
    }
)
"""States from which the state machine allows a pause (dispatch may run)."""


class DrainStatus(str, Enum):
    """One worker's checkpoint observation during the pause drain.

    ``STABLE`` -- the worker is at a stable boundary (idle, or a
    noninterruptible operation has completed): safe to close the attempt.
    ``NONINTERRUPTIBLE_IN_PROGRESS`` -- a noninterruptible operation is
    running to its stable boundary: the drain must wait, never fence while
    it runs.  ``UNRESPONSIVE`` -- no checkpoint: a hung worker, fenced at
    the drain deadline.
    """

    STABLE = "STABLE"
    NONINTERRUPTIBLE_IN_PROGRESS = "NONINTERRUPTIBLE_IN_PROGRESS"
    UNRESPONSIVE = "UNRESPONSIVE"


class RevalidationCheck(str, Enum):
    """The four LIGHT resume revalidation checks (no full discovery).

    ``TIER1_HASH`` -- the locked Tier-1 hash is still the one the paused
    checkpoint recorded; ``CREDENTIAL_FRESHNESS`` -- fresh
    credential/evidence for the providers the next tasks need;
    ``PROVIDER_AVAILABILITY`` -- those providers are available;
    ``TARGET_MARKERS`` -- the target-state markers of the next tasks are
    in place.
    """

    TIER1_HASH = "tier1_hash"
    CREDENTIAL_FRESHNESS = "credential_freshness"
    PROVIDER_AVAILABILITY = "provider_availability"
    TARGET_MARKERS = "target_markers"


CANONICAL_CHECKS = (
    RevalidationCheck.TIER1_HASH,
    RevalidationCheck.CREDENTIAL_FRESHNESS,
    RevalidationCheck.PROVIDER_AVAILABILITY,
    RevalidationCheck.TARGET_MARKERS,
)
"""Canonical order of the four light-revalidation findings."""


class PauseError(RuntimeError):
    """Base class for refused pause/resume operations (fail closed)."""


class NotPausable(PauseError):
    """The run's state cannot be paused from (dispatch is not active)."""


class NotPaused(PauseError):
    """Only a PAUSED run can be resumed."""


class PauseCheckpointMissing(PauseError):
    """The run is PAUSED but no paused checkpoint was ever persisted.

    Durable state is authoritative (spec 22): a resume without the
    durable pause checkpoint is impossible instead of guessed.
    """


class ResumeRevalidationError(PauseError):
    """Light resume revalidation failed: the run stays PAUSED.

    Carries the batched :class:`ResumeRevalidation` findings so the
    controller gets the full consolidated view, never a partial resume.
    """

    def __init__(self, revalidation: "ResumeRevalidation") -> None:
        self.revalidation = revalidation
        failed = [f.check.value for f in revalidation.findings if not f.ok]
        super().__init__(
            "light resume revalidation failed: " + ", ".join(failed)
        )


class PauseDrainAdapterError(PauseError):
    """A pause's drain adapter failed mid-drain (the pause stays durable).

    The ``PAUSED`` transition and a *best-effort* checkpoint WERE
    persisted -- every still-unresolved worker is fenced as hung at the
    pause instant -- so the run is never left ``PAUSED`` without durable
    pause state (spec 22). ``checkpoint`` carries that record;
    ``__cause__`` the adapter failure.
    """

    def __init__(self, checkpoint: "PauseCheckpoint") -> None:
        if not isinstance(checkpoint, PauseCheckpoint):
            raise TypeError(
                f"checkpoint must be a PauseCheckpoint, "
                f"got {type(checkpoint).__name__}"
            )
        self.checkpoint = checkpoint
        super().__init__(
            "pause drain adapter failed; best-effort checkpoint persisted "
            f"({len(checkpoint.tasks)} task(s), unresolved workers fenced)"
        )


class ResumeMutationError(PauseError):
    """A resume aborted inside its guarded mutation phase (fail closed).

    Every effect of the aborted attempt was rolled back (minted leases
    fenced, started clocks refrozen, restored resources re-frozen) and the
    failure was persisted as ``run.resume_failed``; the run stays ``PAUSED``
    and a later resume retries from a clean ledger (never a lease conflict
    with an abandoned live lease). ``cleanup`` is the rolled-back effect
    report; ``__cause__`` the original mutation failure.
    """

    def __init__(self, cleanup: dict[str, list[str]]) -> None:
        self.cleanup = cleanup
        super().__init__(
            "resume aborted inside its mutation phase; run stays PAUSED "
            f"(fenced leases: {', '.join(cleanup['fenced_lease_ids']) or 'none'}, "
            f"refrozen clocks: {', '.join(cleanup['refrozen_clocks']) or 'none'})"
        )


# ---------------------------------------------------------------------------
# Injected adapters (duck-typed; the coordinator never owns policy or raw
# clients -- the fence/freeze/lease authority stays with the ledgers).
# ---------------------------------------------------------------------------


@runtime_checkable
class CheckpointDrain(Protocol):
    """Cooperative pause drain of one running worker.

    ``signal`` tells the worker to stop starting new work and check out at
    its next stable boundary; ``poll`` reports the worker's current
    checkpoint status at ``now``. The coordinator decides, not the adapter:
    a :class:`DrainStatus.STABLE` closes the attempt at its boundary, a
    status past the drain deadline means the worker is fenced.
    """

    def signal(self, task_id: str) -> None: ...

    def poll(self, task_id: str, now: datetime) -> DrainStatus: ...


@runtime_checkable
class TimeBudget(Protocol):
    """The per-task attempt clock a pause freezes / a resume unfreezes.

    Implemented by
    :class:`kcc_autobuild.controller.TaskTimeBudget`: ``freeze`` stops the
    clock consuming the elapsed running time (idempotent), ``start``
    resumes it, ``remaining`` reports the seconds left.
    """

    def freeze(self, now: datetime) -> float: ...

    def start(self, now: datetime) -> None: ...

    def remaining(self, now: datetime) -> float: ...


@runtime_checkable
class ResumeProbe(Protocol):
    """The LIGHT observations of resume revalidation (never full discovery).

    ``provider_available`` asks whether a provider the next tasks need is
    available; ``target_markers_ok`` asks whether a task's target-state
    markers are already in place. The adapter scopes the probe to exactly
    what the resumed set needs.
    """

    def provider_available(self, provider: str, now: datetime) -> bool: ...

    def target_markers_ok(self, task_id: str, now: datetime) -> bool: ...


@runtime_checkable
class ResourceFreezer(Protocol):
    """Contract-bounded freeze of reversible resources during a pause.

    ``freeze_authorized`` answers whether the locked contract allows
    freezing this task's resources; ``freeze`` freezes them and returns
    the frozen resource ids (recorded in the checkpoint);
    ``unfreeze`` restores them on resume.
    """

    def freeze_authorized(self, task_id: str) -> bool: ...

    def freeze(self, task_id: str) -> tuple[str, ...]: ...

    def unfreeze(self, task_id: str) -> None: ...


# ---------------------------------------------------------------------------
# Validation helpers (R7: UTC-only, fail closed, deterministic)
# ---------------------------------------------------------------------------


def _as_utc(value: datetime, name: str = "datetime") -> datetime:
    """Require timezone-aware input and normalize to UTC (R7 discipline)."""
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")
    return value.astimezone(timezone.utc)


def _require_run_id(value: object, name: str = "run_id") -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string, got {type(value).__name__}")
    if re.fullmatch(RUN_ID_PATTERN, value) is None:
        raise ValueError(f"{name} must match {RUN_ID_PATTERN}, got {value!r}")
    return value


def _require_nonempty(value: object, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value


def _require_bool(value: object, name: str) -> None:
    if not isinstance(value, bool):
        raise TypeError(f"{name} must be a bool, got {type(value).__name__}")


def _positive_timedelta(value: object, name: str) -> timedelta:
    if isinstance(value, bool) or not isinstance(value, timedelta):
        raise TypeError(f"{name} must be a timedelta, got {type(value).__name__}")
    if value <= timedelta(0):
        raise ValueError(f"{name} must be strictly positive, got {value}")
    return value


def _normalize_task_ids(task_ids: Iterable[str]) -> tuple[str, ...]:
    parsed: list[str] = []
    for task_id in task_ids:
        parsed.append(_require_nonempty(task_id, "task id"))
    if len(parsed) != len(set(parsed)):
        raise ValueError("task ids must not contain duplicates")
    return tuple(sorted(parsed))


def _normalize_task_providers(
    task_providers: Mapping[str, Sequence[str]] | None,
    task_ids: Iterable[str],
) -> dict[str, tuple[str, ...]]:
    """Deterministic per-task provider sets (sorted, unique, non-blank)."""
    known = set(task_ids)
    normalized: dict[str, tuple[str, ...]] = {}
    for task_id, providers in (task_providers or {}).items():
        _require_nonempty(task_id, "task id")
        if task_id not in known:
            # The provider map covers the whole run; the light revalidation
            # only evaluates the TASKS being resumed (a subset).
            continue
        parsed: list[str] = []
        for provider in providers:
            parsed.append(_require_nonempty(provider, "provider"))
        if len(parsed) != len(set(parsed)):
            raise ValueError(
                f"task_providers[{task_id!r}] must not contain duplicates"
            )
        normalized[task_id] = tuple(sorted(parsed))
    return normalized


def _bool_mapping(
    value: Mapping[str, bool] | None,
    name: str,
) -> dict[str, bool]:
    normalized: dict[str, bool] = {}
    for key, flag in (value or {}).items():
        _require_nonempty(key, f"{name} key")
        _require_bool(flag, f"{name}[{key!r}]")
        normalized[key] = flag
    return normalized


# ---------------------------------------------------------------------------
# Pure decisions
# ---------------------------------------------------------------------------


def contract_allows_reversible_freeze(
    contract: BuildContract,
    operations: Iterable[str],
) -> bool:
    """Whether the locked Tier-1 destructive policy classifies ALL operations
    reversible.

    Reversible means the resource can be restored later (``REVERSIBLE_
    AUTONOMOUS`` or ``REVERSIBLE_WITH_ROLLBACK_REQUIRED``): only then may
    the pause freeze it. An operation with no policy classification -- or
    classified irreversible -- makes the freeze NOT authorized, and an
    empty operation set authorizes nothing (there is nothing to freeze).
    """
    if not isinstance(contract, BuildContract):
        raise TypeError(
            f"contract must be a BuildContract, got {type(contract).__name__}"
        )
    operations = tuple(_require_nonempty(op, "operation") for op in operations)
    if not operations:
        return False
    if len(operations) != len(set(operations)):
        raise ValueError("operations must not contain duplicates")
    classifications = {
        rule.operation: rule.classification
        for rule in contract.tier1.destructive_policy
    }
    reversible = {
        DestructiveAction.REVERSIBLE_AUTONOMOUS,
        DestructiveAction.REVERSIBLE_WITH_ROLLBACK_REQUIRED,
    }
    return all(
        classifications.get(operation) in reversible for operation in operations
    )


def _credentials_fresh(
    contract: BuildContract,
    providers: tuple[str, ...],
    now: datetime,
) -> bool:
    """Fresh credential/evidence for ONE provider set (light, no probes).

    The packed readiness evidence decides -- never a provider probe: for
    every readiness item of the needed providers, the declared READY
    status must hold with current pass evidence inside its freshness
    window (the same evidence-backed semantics the LOCK gate uses). A
    needed provider with NO readiness evidence at all is not fresh (fail
    closed); a task with no providers needs nothing.
    """
    if not providers:
        return True
    items = [
        item
        for item in contract.readiness.items
        if item.provider in providers
    ]
    if not items:
        return False
    evaluation = evaluate_readiness(ReadinessPack(items=items), now=now)
    return evaluation.ready


def evaluate_light_revalidation(
    contract: BuildContract,
    *,
    task_ids: Iterable[str] = (),
    task_providers: Mapping[str, Sequence[str]] | None = None,
    providers_available: Mapping[str, bool] | None = None,
    markers_ok: Mapping[str, bool] | None = None,
    locked_hash: str | None = None,
    now: datetime | None = None,
) -> "ResumeRevalidation":
    """Run the four LIGHT revalidation checks for the resumed task set.

    Pure and deterministic (sorted ids, no I/O, no probes):
    ``TIER1_HASH`` -- the contract is locked, its canonical Tier-1 hash
    is self-consistent, and (when a pause-time ``locked_hash`` is handed
    in) unchanged since the pause; ``CREDENTIAL_FRESHNESS`` -- per-task
    packed-evidence freshness of the task's providers;
    ``PROVIDER_AVAILABILITY`` -- every needed provider observed available
    (an unobserved provider is NOT available: fail closed);
    ``TARGET_MARKERS`` -- every task's target-state markers observed in
    place (an unobserved task is NOT ok: fail closed).
    """
    if not isinstance(contract, BuildContract):
        raise TypeError(
            f"contract must be a BuildContract, got {type(contract).__name__}"
        )
    tasks = _normalize_task_ids(task_ids)
    providers = _normalize_task_providers(task_providers, tasks)
    availability = _bool_mapping(providers_available, "providers_available")
    markers = _bool_mapping(markers_ok, "markers_ok")
    if locked_hash is not None and not (
        isinstance(locked_hash, str)
        and re.fullmatch(CONTRACT_HASH_PATTERN, locked_hash) is not None
    ):
        raise ValueError(
            "locked_hash must be a canonical 64-hex sha256 when present"
        )
    now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")

    # 1) locked Tier-1 hash (spec 14 / R7: the canonical hash binds the lock)
    hash_consistent = (
        contract.locked_at is not None
        and contract.contract_hash is not None
        and contract.contract_hash == tier1_canonical_hash(contract)
    )
    if locked_hash is not None:
        hash_consistent = hash_consistent and locked_hash == contract.contract_hash
    if hash_consistent:
        hash_detail = "locked Tier-1 canonical hash is unchanged"
    else:
        hash_detail = (
            "the locked Tier-1 hash does not match the paused checkpoint "
            "(contract re-issued or never locked)"
        )

    # 2) credential/evidence freshness needed for the next tasks
    fresh_by_task = {
        task_id: _credentials_fresh(
            contract, providers.get(task_id, ()), now
        )
        for task_id in tasks
    }
    if all(fresh_by_task.values()):
        credential_detail = (
            "fresh credential/evidence for: " + ", ".join(tasks)
            if tasks
            else "no credentials needed (no resumed tasks)"
        )
        credential_ok = True
    else:
        stale = sorted(
            task_id for task_id, fresh in fresh_by_task.items() if not fresh
        )
        credential_ok = False
        credential_detail = (
            "stale or missing credential/evidence for: " + ", ".join(stale)
        )

    # 3) provider availability for the next tasks (unobserved => unavailable)
    avail_by_task = {
        task_id: all(
            availability.get(provider, False)
            for provider in providers.get(task_id, ())
        )
        for task_id in tasks
    }
    if all(avail_by_task.values()):
        availability_detail = (
            "providers available for: " + ", ".join(tasks)
            if tasks
            else "no providers needed (no resumed tasks)"
        )
        availability_ok = True
    else:
        blocked = sorted(
            task_id for task_id, ok in avail_by_task.items() if not ok
        )
        availability_ok = False
        availability_detail = (
            "providers unavailable or unverified for: " + ", ".join(blocked)
        )

    # 4) target-state markers without full discovery (unobserved => not ok)
    if all(markers.get(task_id, False) for task_id in tasks):
        markers_detail = (
            "target-state markers in place for: " + ", ".join(tasks)
            if tasks
            else "no target markers needed (no resumed tasks)"
        )
        markers_ok_value = True
    else:
        missing = sorted(
            task_id
            for task_id in tasks
            if not markers.get(task_id, False)
        )
        markers_ok_value = False
        markers_detail = (
            "target-state markers not in place for: " + ", ".join(missing)
        )

    return ResumeRevalidation(
        findings=[
            RevalidationFinding(
                check=RevalidationCheck.TIER1_HASH,
                ok=hash_consistent,
                detail=hash_detail,
            ),
            RevalidationFinding(
                check=RevalidationCheck.CREDENTIAL_FRESHNESS,
                ok=credential_ok,
                detail=credential_detail,
            ),
            RevalidationFinding(
                check=RevalidationCheck.PROVIDER_AVAILABILITY,
                ok=availability_ok,
                detail=availability_detail,
            ),
            RevalidationFinding(
                check=RevalidationCheck.TARGET_MARKERS,
                ok=markers_ok_value,
                detail=markers_detail,
            ),
        ]
    )


# ---------------------------------------------------------------------------
# Durable models (the checkpoint/persisted findings serialize deterministically)
# ---------------------------------------------------------------------------


class RevalidationFinding(StrictModel):
    """Outcome of one light revalidation check.

    ``check`` selects the canonical check, ``ok`` its verdict and
    ``detail`` the deterministic human-readable reason.
    """

    check: RevalidationCheck
    ok: bool
    detail: str = ""

    @field_validator("detail")
    @classmethod
    def _detail_is_text(cls, value: str) -> str:
        if not isinstance(value, str):
            raise TypeError(
                f"detail must be a str, got {type(value).__name__}"
            )
        if not value.strip():
            raise ValueError("detail must not be blank")
        return value


class ResumeRevalidation(StrictModel):
    """The batched outcome of the four light revalidation checks.

    ``findings`` always carries exactly the four canonical checks in
    canonical order (deterministic, fail closed); ``ok`` is derived:
    every check must pass. The batched view is persisted on rejection so
    the controller sees the whole set, never one finding at a time.
    """

    findings: list[RevalidationFinding]

    @field_validator("findings")
    @classmethod
    def _canonical_checks(cls, value: list[RevalidationFinding]) -> list[RevalidationFinding]:
        checks = tuple(item.check for item in value)
        if checks != CANONICAL_CHECKS:
            raise ValueError(
                "findings must carry exactly the four canonical "
                "light-revalidation checks in canonical order "
                f"(got {[check.value for check in checks]})"
            )
        return value

    @computed_field  # type: ignore[prop-decorator]
    @property
    def ok(self) -> bool:
        """Whether every light revalidation check passed."""
        return all(item.ok for item in self.findings)


class ReservedRateDemand(StrictModel):
    """One task's pinned rate reservation (the pause-time ledger value).

    ``provider_key`` + ``units`` mirror :class:`kcc_autobuild.rate_limit.
    RateDemand` so the durable checkpoint records *exactly* what the pause
    retained and the resume revalidation can fail closed on a lost or
    altered rate booking (never a silent re-reserve).
    """

    provider_key: str
    units: int = 1

    @field_validator("provider_key")
    @classmethod
    def _provider_key_nonblank(cls, value: str) -> str:
        return _require_nonempty(value, "reserved_rate.provider_key")

    @field_validator("units")
    @classmethod
    def _units_positive_int(cls, value: int) -> int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise TypeError(
                f"reserved_rate.units must be an int, "
                f"got {type(value).__name__}"
            )
        if value < 1:
            raise ValueError("reserved_rate.units must be positive")
        return value


class PausedTaskState(StrictModel):
    """One paused task's durable drain/fence/freeze record.

    ``drained`` -- reached a stable boundary before the drain deadline;
    ``boundary_waited`` -- a noninterruptible operation was observed in
    flight and ran to its boundary; ``hung`` (== not ``drained``) -- the
    deadline arrived first and the worker was fenced; ``fenced`` -- the
    attempt's lease is revoked after the pause; ``elapsed_seconds`` /
    ``time_remaining`` are the frozen clock values; ``terminal`` -- the
    time budget was exhausted at the boundary (the only case where the
    retained booking is released); ``reservation_retained`` -- resume
    reservation kept by default; ``reserved_money`` / ``reserved_rate``
    pin the retained booking amounts (``None`` when that ledger held no
    booking) so resume validates both ledgers exactly; ``resources_frozen``
    -- reversible resources the contract allowed freezing.
    """

    task_id: str
    drained: bool
    boundary_waited: bool
    hung: bool
    fenced: bool
    elapsed_seconds: float
    time_remaining: float
    terminal: bool
    reservation_retained: bool
    reserved_money: str | None = None
    reserved_rate: ReservedRateDemand | None = None
    resources_frozen: list[str] = []

    @field_validator("task_id")
    @classmethod
    def _task_id_not_blank(cls, value: str) -> str:
        return _require_nonempty(value, "task_id")

    @field_validator(
        "drained",
        "boundary_waited",
        "hung",
        "fenced",
        "terminal",
        "reservation_retained",
    )
    @classmethod
    def _flags_are_bools(cls, value: bool, info: ValidationInfo) -> bool:
        _require_bool(value, info.field_name)
        return value

    @field_validator("reserved_money")
    @classmethod
    def _money_pin_is_decimal_text(
        cls, value: str | None
    ) -> str | None:
        if value is None:
            return None
        return _require_nonempty(value, "reserved_money")

    @field_validator("reserved_rate")
    @classmethod
    def _rate_pin_is_model(cls, value: ReservedRateDemand | None) -> ReservedRateDemand | None:
        if value is None:
            return None
        if not isinstance(value, ReservedRateDemand):
            raise TypeError(
                "reserved_rate must be a ReservedRateDemand, "
                f"got {type(value).__name__}"
            )
        return value

    @field_validator("elapsed_seconds", "time_remaining")
    @classmethod
    def _seconds_are_numbers(
        cls, value: float, info: ValidationInfo
    ) -> float:
        if isinstance(value, bool) or not isinstance(value, float):
            raise TypeError(
                f"{info.field_name} must be a float, "
                f"got {type(value).__name__}"
            )
        if value < 0 and info.field_name == "elapsed_seconds":
            raise ValueError("elapsed_seconds must not be negative")
        return value

    @field_validator("resources_frozen")
    @classmethod
    def _resources_unique_nonblank(cls, value: list[str]) -> list[str]:
        parsed = [
            _require_nonempty(resource, "resources_frozen entry")
            for resource in value
        ]
        if len(parsed) != len(set(parsed)):
            raise ValueError("resources_frozen must not contain duplicates")
        return parsed

    @model_validator(mode="after")
    def _hung_means_not_drained(self) -> "PausedTaskState":
        if self.hung == self.drained:
            raise ValueError(
                "hung must be True exactly when the worker was NOT drained"
            )
        if self.terminal and self.reservation_retained:
            raise ValueError(
                "a terminal task (time budget exhausted) cannot retain a "
                "resume reservation -- the booking would leak through the pause"
            )
        return self


class PauseCheckpoint(StrictModel):
    """The durable pause checkpoint persisted before/with ``PAUSED``.

    Records the pause instant, the Tier-1 hash at pause (so resume can
    detect a re-issue), the drain deadline, whether reversible-resource
    freezing was requested, the pinned reservation universe
    (``reserved_task_ids`` -- every task holding money and/or rate
    bookings when the pause began, including reserved-but-not-running
    bookings, so the resume rebalance reconciles a deterministic,
    auditable set), and one :class:`PausedTaskState` per running task --
    durable run state (spec 22), never conversational memory.
    """

    run_id: str
    paused_at: datetime
    contract_hash: str | None = None
    drain_timeout_seconds: float = DEFAULT_DRAIN_TIMEOUT.total_seconds()
    freeze_reversible_resources: bool = False
    reserved_task_ids: list[str] = []
    tasks: list[PausedTaskState] = []

    @field_validator("run_id")
    @classmethod
    def _run_id_is_canonical_identity(cls, value: str) -> str:
        return _require_run_id(value)

    @field_validator("paused_at")
    @classmethod
    def _paused_at_aware_utc(cls, value: datetime) -> datetime:
        return _as_utc(value, "paused_at")

    @field_validator("contract_hash")
    @classmethod
    def _hash_is_hex(cls, value: str | None) -> str | None:
        if value is not None and not (
            isinstance(value, str)
            and re.fullmatch(CONTRACT_HASH_PATTERN, value) is not None
        ):
            raise ValueError("contract_hash must be a canonical 64-hex sha256")
        return value

    @field_validator("drain_timeout_seconds")
    @classmethod
    def _deadline_positive(cls, value: float) -> float:
        if isinstance(value, bool) or not isinstance(value, float):
            raise TypeError(
                "drain_timeout_seconds must be a float, "
                f"got {type(value).__name__}"
            )
        if value <= 0:
            raise ValueError("drain_timeout_seconds must be strictly positive")
        return value

    @field_validator("freeze_reversible_resources")
    @classmethod
    def _freeze_flag_is_bool(cls, value: bool) -> bool:
        _require_bool(value, "freeze_reversible_resources")
        return value

    @field_validator("reserved_task_ids")
    @classmethod
    def _reserved_ids_sorted_unique(cls, value: list[str]) -> list[str]:
        return list(_normalize_task_ids(value))

    @field_validator("tasks")
    @classmethod
    def _tasks_unique(cls, value: list[PausedTaskState]) -> list[PausedTaskState]:
        task_ids = [task.task_id for task in value]
        if len(task_ids) != len(set(task_ids)):
            raise ValueError("checkpoint tasks must not contain duplicates")
        return value


class ContractResourceFreezer:
    """Contract-bounded :class:`ResourceFreezer` over the Tier-1 policy.

    ``task_resources`` maps each task to the operation names covering its
    resources; the freeze is authorized exactly when the locked
    destructive policy classifies ALL of them reversible (spec 14.5:
    destructive/mutating operations policy-classified before execution).
    The freezer is a state machine, not a policy-only stub: ``freeze``
    records the frozen resource set (and returns it, exactly what the
    checkpoint records), ``unfreeze`` restores it, and
    :meth:`is_frozen` / :meth:`frozen_resources` expose the applied
    freeze state so a paused run's frozen resources are observable and
    auditable -- never an audit-only field.
    """

    def __init__(
        self,
        contract: BuildContract,
        task_resources: Mapping[str, Sequence[str]],
    ) -> None:
        if not isinstance(contract, BuildContract):
            raise TypeError(
                f"contract must be a BuildContract, got {type(contract).__name__}"
            )
        self._contract = contract
        self._task_resources: dict[str, tuple[str, ...]] = {}
        for task_id, operations in task_resources.items():
            task_id = _require_nonempty(task_id, "task id")
            parsed: list[str] = [
                _require_nonempty(operation, "operation") for operation in operations
            ]
            if len(parsed) != len(set(parsed)):
                raise ValueError(
                    f"task_resources[{task_id!r}] must not contain duplicates"
                )
            self._task_resources[task_id] = tuple(sorted(parsed))
        self._frozen: dict[str, tuple[str, ...]] = {}

    def freeze_authorized(self, task_id: str) -> bool:
        return contract_allows_reversible_freeze(
            self._contract, self._task_resources.get(task_id, ())
        )

    def freeze(self, task_id: str) -> tuple[str, ...]:
        if not self.freeze_authorized(task_id):
            raise PauseError(
                f"task {task_id!r} resources are not classified reversible "
                "by the locked Tier-1 destructive policy"
            )
        resources = self._task_resources[task_id]
        self._frozen[task_id] = resources
        return resources

    def unfreeze(self, task_id: str) -> None:
        self._frozen.pop(task_id, None)

    def is_frozen(self, task_id: str) -> bool:
        """Whether the task's resources are currently frozen."""
        return task_id in self._frozen

    def frozen_resources(self, task_id: str) -> tuple[str, ...]:
        """The frozen resource set for the task (``()`` when not frozen)."""
        return self._frozen.get(task_id, ())


# ---------------------------------------------------------------------------
# Coordinator
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PauseOutcome:
    """Result of :meth:`PauseCoordinator.pause`.

    ``checkpoint`` is the persisted :class:`PauseCheckpoint`;
    ``fenced`` lists **every running task** in deterministic order -- the
    pause closes ALL of them by fencing the attempt's lease (a drained
    attempt at its stable boundary, a hung attempt at the deadline), so
    this is not a hung-only set; the checkpoint's per-task
    ``drained``/``hung``/``fenced`` flags distinguish the two; ``released``
    the (terminal) tasks whose retained booking had to be released.
    """

    run_id: str
    checkpoint: PauseCheckpoint
    fenced: tuple[str, ...] = ()
    released: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _require_run_id(self.run_id)
        if not isinstance(self.checkpoint, PauseCheckpoint):
            raise TypeError(
                "checkpoint must be a PauseCheckpoint, "
                f"got {type(self.checkpoint).__name__}"
            )
        for name in ("fenced", "released"):
            value = getattr(self, name)
            if not isinstance(value, tuple):
                raise TypeError(f"{name} must be a tuple")
            for task_id in value:
                _require_nonempty(task_id, f"{name} entry")
            if len(set(value)) != len(value):
                raise ValueError(f"{name} must not contain duplicates")


@dataclass(frozen=True)
class ResumeOutcome:
    """Result of :meth:`PauseCoordinator.resume`.

    ``revalidation`` is the passed light revalidation;
    ``fresh_leases`` one minted lease per resumed task; ``released`` the
    tasks whose reservation was rebalanced away; ``resumed`` the tasks
    re-enabled (fresh lease + unfrozen clock).
    """

    run_id: str
    revalidation: ResumeRevalidation
    fresh_leases: tuple[Lease, ...] = ()
    released: tuple[str, ...] = ()
    resumed: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _require_run_id(self.run_id)
        if not isinstance(self.revalidation, ResumeRevalidation):
            raise TypeError(
                "revalidation must be a ResumeRevalidation, "
                f"got {type(self.revalidation).__name__}"
            )
        for lease in self.fresh_leases:
            if not isinstance(lease, Lease):
                raise TypeError(
                    f"fresh_leases entries must be Lease, got {type(lease).__name__}"
                )
        for name in ("released", "resumed"):
            value = getattr(self, name)
            if not isinstance(value, tuple):
                raise TypeError(f"{name} must be a tuple")
            for task_id in value:
                _require_nonempty(task_id, f"{name} entry")
            if len(set(value)) != len(value):
                raise ValueError(f"{name} must not contain duplicates")


class PauseCoordinator:
    """The PAUSED drain/fence/freeze + light-resume coordinator (one run).

    All components are injected (store / leases / budget / rate /
    clocks / contract / drain / probe / optional resource freezer) so the
    semantics are testable and the ledgers stay the single authority on
    money, rate and attempt identity. ``now`` defaults to the wall clock
    when a caller does not hand one in; every handed-in ``now`` is
    normalized to UTC (R7).
    """

    def __init__(
        self,
        *,
        run_id: str,
        store: RunStore,
        leases: LeaseLedger | LeaseStore,
        budget: BudgetLedger,
        rate: RateCapacityLedger,
        clocks: Mapping[str, TimeBudget],
        contract: BuildContract,
        drain: CheckpointDrain,
        probe: ResumeProbe,
        resources: ResourceFreezer | None = None,
        task_providers: Mapping[str, Sequence[str]] | None = None,
        poll_interval: timedelta = DEFAULT_POLL_INTERVAL,
    ) -> None:
        run_id = _require_run_id(run_id)
        if not isinstance(store, RunStore):
            raise TypeError(f"store must be a RunStore, got {type(store).__name__}")
        if not isinstance(leases, (LeaseLedger, LeaseStore)):
            raise TypeError(
                "leases must be a LeaseLedger or LeaseStore, "
                f"got {type(leases).__name__}"
            )
        if not isinstance(budget, BudgetLedger):
            raise TypeError(
                f"budget must be a BudgetLedger, got {type(budget).__name__}"
            )
        if not isinstance(rate, RateCapacityLedger):
            raise TypeError(
                f"rate must be a RateCapacityLedger, got {type(rate).__name__}"
            )
        if not isinstance(contract, BuildContract):
            raise TypeError(
                f"contract must be a BuildContract, got {type(contract).__name__}"
            )
        if not isinstance(drain, CheckpointDrain):
            raise TypeError(
                f"drain must be a CheckpointDrain, got {type(drain).__name__}"
            )
        if not isinstance(probe, ResumeProbe):
            raise TypeError(
                f"probe must be a ResumeProbe, got {type(probe).__name__}"
            )
        if resources is not None and not isinstance(resources, ResourceFreezer):
            raise TypeError(
                "resources must be a ResourceFreezer, "
                f"got {type(resources).__name__}"
            )
        _positive_timedelta(poll_interval, "poll_interval")
        task_ids = tuple(clocks)
        clocks = {
            _require_nonempty(task_id, "clock task id"): clock
            for task_id, clock in clocks.items()
        }
        if len(clocks) != len(task_ids):
            raise ValueError("duplicate clock task ids")
        for task_id, clock in clocks.items():
            if not isinstance(clock, TimeBudget):
                raise TypeError(
                    f"clock for task {task_id!r} must be a TimeBudget, "
                    f"got {type(clock).__name__}"
                )
        # The run must exist before events can reference it (FKs).
        store.load_run(run_id)
        self.run_id = run_id
        self.store = store
        self.leases = leases
        self.budget = budget
        self.rate = rate
        self.clocks = clocks
        self.contract = contract
        self._drain = drain
        self._probe = probe
        self._resources = resources
        self._poll_interval = poll_interval
        self._task_providers = _normalize_task_providers(
            task_providers, sorted(clocks)
        )

    # -- durable views --------------------------------------------------------

    def checkpoint(self) -> PauseCheckpoint | None:
        """The persisted pause checkpoint (``None`` if never paused)."""
        return self._load_checkpoint()

    # -- pause ----------------------------------------------------------------

    def pause(
        self,
        *,
        now: datetime | None = None,
        drain_timeout: timedelta = DEFAULT_DRAIN_TIMEOUT,
        freeze_reversible_resources: bool = False,
    ) -> PauseOutcome:
        """Pause the run: stop dispatch, drain checkpoints, fence, freeze.

        Order (pinned by the contract): the durable ``PAUSED`` transition
        stops NEW DISPATCH first; every running worker is signalled to
        check out; the drain runs at a fixed poll interval until each
        worker is at a stable boundary or the deadline arrives (a
        noninterruptible operation runs to its stable boundary -- never
        fenced while it runs; a worker not at a boundary by the deadline
        is a hung worker and is fenced); each attempt's lease is fenced,
        its time budget frozen at the resolution instant, its resume
        reservation retained by default (released only when the time
        budget is exhausted -- the task is terminal); reversible
        resources are frozen only when requested and only when the
        contract's freezer authorizes it; and the paused checkpoint is
        persisted => ``PAUSED``. A drain adapter failure mid-drain does
        NOT strand the run: the unresolved workers are fenced as hung at
        the pause instant, the best-effort checkpoint is persisted and
        :class:`PauseDrainAdapterError` is raised (fail closed).
        """
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        drain_timeout = _positive_timedelta(drain_timeout, "drain_timeout")
        _require_bool(freeze_reversible_resources, "freeze_reversible_resources")
        if freeze_reversible_resources and self._resources is None:
            raise PauseError(
                "freeze_reversible_resources requires a resource freezer; "
                "refusing to freeze against an unknown contract surface"
            )
        record = self.store.load_run(self.run_id)
        if record.state not in _PAUSABLE_STATES:
            raise NotPausable(
                f"a {record.state.value} run cannot be paused "
                "(dispatch is not active)"
            )
        pause_at = now
        running = [
            task_id
            for task_id in sorted(self.clocks)
            if self._running_lease(task_id, now) is not None
        ]
        # Pin the reservation universe BEFORE any release: every booking the
        # pause retains (including reserved-but-not-running bookings) is
        # recorded in the checkpoint so the resume rebalance reconciles a
        # deterministic, auditable set instead of silently releasing an
        # unpinned booking.
        reserved_task_ids = sorted(set(self._reservation_universe()))

        # 1) Stop new dispatch: the durable PAUSED transition happens FIRST,
        # so nothing new can be dispatched while the drain is still running.
        self.store.transition(
            self.run_id,
            record.state,
            LifecycleState.PAUSED,
            "pause requested (new dispatch stopped)",
        )

        # 2) Signal every running worker to check out at its next boundary.
        # 3) Drain at a fixed poll interval (deterministic tick advance); an
        # adapter failure fails closed: the still-unresolved workers are
        # treated as hung at the pause instant, never stranded uncheckpointed.
        statuses: dict[str, DrainStatus] = {}
        resolved_at: dict[str, datetime] = {}
        boundary_waited: set[str] = set()
        pending = list(running)
        drain_failure: Exception | None = None
        try:
            for task_id in running:
                self._drain.signal(task_id)
            tick = now
            deadline = now + drain_timeout
            while True:
                for task_id in pending:
                    status = self._drain.poll(task_id, tick)
                    statuses[task_id] = status
                    resolved_at[task_id] = tick
                    if status is DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS:
                        boundary_waited.add(task_id)
                pending = [
                    task_id
                    for task_id in pending
                    if statuses[task_id] is not DrainStatus.STABLE
                ]
                if not pending:
                    break
                if tick >= deadline:
                    break  # hung workers: fenced below
                tick = min(tick + self._poll_interval, deadline)
        except Exception as exc:
            # The PAUSED transition is already durable: a drain adapter
            # failure must not leave the run PAUSED without a checkpoint
            # (spec 22). An unobservable boundary is not a stable boundary,
            # so the unresolved workers are hung/fenced at the pause instant.
            drain_failure = exc
            for task_id in pending:
                statuses[task_id] = DrainStatus.UNRESPONSIVE
                resolved_at[task_id] = now

        # 4) Fence / freeze / retain / pin per task at its resolution instant.
        paused_tasks: list[PausedTaskState] = []
        released: list[str] = []
        for task_id in running:
            status = statuses[task_id]
            resolved = resolved_at[task_id]
            drained = status is DrainStatus.STABLE
            fenced_now = self._fence_if_live(task_id, resolved)
            clock = self.clocks[task_id]
            elapsed = clock.freeze(resolved)
            remaining = clock.remaining(resolved)
            terminal = remaining <= 0
            retained = not terminal
            # Pin what the pause retains BEFORE the terminal release, so the
            # resume revalidation can fail closed on a lost OR altered
            # booking on BOTH ledgers (never a silent re-reserve).
            money_pin = (
                str(self.budget.reservations[task_id])
                if task_id in self.budget.reservations
                else None
            )
            rate_demand = self.rate.reservations.get(task_id)
            rate_pin = (
                ReservedRateDemand(
                    provider_key=rate_demand.provider_key,
                    units=rate_demand.units,
                )
                if rate_demand is not None
                else None
            )
            if terminal:
                self._release_reservation(task_id)
                released.append(task_id)
            frozen_resources: list[str] = []
            # Reversible resources are frozen only for non-terminal tasks: a
            # terminal task is failed, so its resources must stay recoverable
            # for the resume (nothing to resume) -- never left frozen.
            if (
                freeze_reversible_resources
                and not terminal
                and self._resources.freeze_authorized(task_id)
            ):
                frozen_resources = list(self._resources.freeze(task_id))
            paused_tasks.append(
                PausedTaskState(
                    task_id=task_id,
                    drained=drained,
                    boundary_waited=task_id in boundary_waited,
                    hung=not drained,
                    fenced=fenced_now,
                    elapsed_seconds=elapsed,
                    time_remaining=remaining,
                    terminal=terminal,
                    reservation_retained=retained,
                    reserved_money=money_pin,
                    reserved_rate=rate_pin,
                    resources_frozen=frozen_resources,
                )
            )

        # 5) Persist the paused checkpoint => PAUSED (also on an adapter
        # failure: the best-effort record is durable before the error rises).
        checkpoint = PauseCheckpoint(
            run_id=self.run_id,
            paused_at=pause_at,
            contract_hash=self.contract.contract_hash,
            drain_timeout_seconds=drain_timeout.total_seconds(),
            freeze_reversible_resources=freeze_reversible_resources,
            reserved_task_ids=reserved_task_ids,
            tasks=paused_tasks,
        )
        self._emit("run.paused", checkpoint.model_dump(mode="json"), pause_at)
        if drain_failure is not None:
            raise PauseDrainAdapterError(checkpoint) from drain_failure
        return PauseOutcome(
            run_id=self.run_id,
            checkpoint=checkpoint,
            fenced=tuple(running),
            released=tuple(released),
        )

    # -- resume ---------------------------------------------------------------

    def resume(self, *, now: datetime | None = None) -> ResumeOutcome:
        """Light-revalidate, rebalance, mint fresh leases, unfreeze, dispatch.

        A paused run resumes ONLY after the four light checks pass (no
        full discovery); on failure nothing moves and the batched findings
        are persisted (``run.resume_rejected``) and raised. On success the
        reservation is rebalanced to the resumed set against the PINNED
        checkpoint universe (never a new reservation -- exactly once; a
        resumed task whose retained money OR rate booking was lost while
        paused is a broken ledger and fails closed), a fresh lease
        generation is minted per resumed task, the time budget continues
        (unfrozen), frozen reversible resources are restored, dispatch is
        enabled (``PAUSED -> RESUMING -> BUILDING``) and the resume event
        is persisted => ``BUILDING``. The whole mutation phase is one
        guarded block: any failure rolls every effect back (minted leases
        fenced, started clocks refrozen, restored resources re-frozen),
        persists ``run.resume_failed`` and raises
        :class:`ResumeMutationError` -- the run stays PAUSED and the next
        resume retries from a clean ledger.
        """
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        record = self.store.load_run(self.run_id)
        if record.state is not LifecycleState.PAUSED:
            raise NotPaused(
                f"only a PAUSED run can resume, run is {record.state.value}"
            )
        checkpoint = self._load_checkpoint()
        if checkpoint is None:
            raise PauseCheckpointMissing(
                "run is PAUSED without a persisted pause checkpoint; refusing "
                "to reconstruct resume state from memory (spec 22)"
            )
        resumed_tasks = tuple(
            task.task_id
            for task in sorted(checkpoint.tasks, key=lambda item: item.task_id)
            if not task.terminal
        )

        # Light resume revalidation (no full discovery, fail closed).
        needed_providers = sorted(
            {
                provider
                for task_id in resumed_tasks
                for provider in self._task_providers.get(task_id, ())
            }
        )
        providers_available = {
            provider: self._probe.provider_available(provider, now)
            for provider in needed_providers
        }
        markers_ok = {
            task_id: self._probe.target_markers_ok(task_id, now)
            for task_id in resumed_tasks
        }
        revalidation = evaluate_light_revalidation(
            self.contract,
            task_ids=resumed_tasks,
            task_providers=self._task_providers,
            providers_available=providers_available,
            markers_ok=markers_ok,
            locked_hash=checkpoint.contract_hash,
            now=now,
        )
        if not revalidation.ok:
            self._emit(
                "run.resume_rejected",
                {
                    "revalidation_ok": False,
                    "findings": [
                        finding.model_dump(mode="json")
                        for finding in revalidation.findings
                    ],
                },
                now,
            )
            raise ResumeRevalidationError(revalidation)

        # -- guarded mutation phase: rebalance, restore, mint, unfreeze,
        # dispatch. A failure at ANY point is all-or-nothing: the run stays
        # PAUSED, every effect is rolled back (minted leases fenced, started
        # clocks refrozen, restored resources re-frozen), the abort is
        # persisted as ``run.resume_failed`` and the retry starts from a
        # clean ledger -- never a lease conflict with a leaked live lease.
        # Pinned fail-closed rejections (lost/altered booking, frozen
        # resources that cannot be restored) raise BEFORE any mutation and
        # propagate as :class:`PauseError` directly.
        state_by_task = {task.task_id: task for task in checkpoint.tasks}
        fresh_leases: list[Lease] = []
        started_clocks: list[str] = []
        restored_resources: list[str] = []
        released: list[str] = []
        try:
            # Pinned preconditions (pure reads): a resumed task whose
            # retained booking was lost or altered while paused is a broken
            # ledger and fails closed on BOTH money and rate; the frozen
            # resource set must be restorable for the resumed set.
            for task_id in resumed_tasks:
                state = state_by_task[task_id]
                if state.reserved_money is not None:
                    if self.budget.reservations.get(task_id) != Decimal(
                        state.reserved_money
                    ):
                        raise PauseError(
                            f"task {task_id!r} lost its retained reservation "
                            "while paused; refusing to re-reserve (exactly once)"
                        )
                if state.reserved_rate is not None:
                    pinned_demand = RateDemand(
                        state.reserved_rate.provider_key,
                        state.reserved_rate.units,
                    )
                    if self.rate.reservations.get(task_id) != pinned_demand:
                        raise PauseError(
                            f"task {task_id!r} lost its retained rate "
                            "reservation while paused; refusing to re-reserve "
                            "(exactly once)"
                        )
            if self._resources is not None:
                for task in checkpoint.tasks:
                    if task.resources_frozen and task.task_id not in resumed_tasks:
                        raise PauseError(
                            f"task {task.task_id!r} has frozen resources but "
                            "is not resumed"
                        )
            elif any(task.resources_frozen for task in checkpoint.tasks):
                raise PauseError(
                    "the paused checkpoint froze resources but no resource "
                    "freezer is available to restore them"
                )

            # Rebalance the reservation against the PINNED universe: every
            # booking the pause recorded (including reserved-but-not-running
            # bookings) plus any booking that appeared while paused, that
            # does not belong to a resumed task, is released -- never a new
            # reservation (exactly once). A later abort keeps these releases
            # applied: a retry re-runs the same deterministic rebalance.
            pinned_universe = set(checkpoint.reserved_task_ids)
            current_universe = set(self._reservation_universe())
            for task_id in sorted(
                (pinned_universe | current_universe) - set(resumed_tasks)
            ):
                if task_id in current_universe:
                    self._release_reservation(task_id)
                    released.append(task_id)

            # Restore reversible resources frozen at pause (the resumed tasks
            # only; the precondition was validated above).
            if self._resources is not None:
                for task in checkpoint.tasks:
                    if task.resources_frozen:
                        self._resources.unfreeze(task.task_id)
                        restored_resources.append(task.task_id)

            # Mint a fresh lease generation and unfreeze the time budget
            # (the SAME clock continues: pause consumed the elapsed time only).
            for task_id in resumed_tasks:
                fresh_leases.append(
                    self.leases.claim(self.run_id, task_id, now=now)
                )
            for task_id in resumed_tasks:
                self.clocks[task_id].start(now)
                started_clocks.append(task_id)

            # Enable dispatch (the durable transitions close the attempt).
            self.store.transition(
                self.run_id,
                LifecycleState.PAUSED,
                LifecycleState.RESUMING,
                "autopilot resuming after light revalidation",
            )
            self.store.transition(
                self.run_id,
                LifecycleState.RESUMING,
                LifecycleState.BUILDING,
                "autopilot resumed",
            )
        except PauseError:
            # Expected fail-closed rejection: nothing was mutated yet.
            raise
        except Exception as exc:
            cleanup = self._rollback_resume(
                fresh_leases, started_clocks, restored_resources, now
            )
            self._emit(
                "run.resume_failed",
                {
                    "phase": "mutation",
                    "error": f"{type(exc).__name__}: {exc}",
                    "minted_lease_ids": [
                        lease.lease_id for lease in fresh_leases
                    ],
                    "released_tasks": list(released),
                    "fenced_lease_ids": cleanup["fenced_lease_ids"],
                    "refrozen_clocks": cleanup["refrozen_clocks"],
                    "refrozen_resources": cleanup["refrozen_resources"],
                },
                now,
            )
            raise ResumeMutationError(cleanup) from exc

        completed_leases = tuple(lease.lease_id for lease in fresh_leases)
        self._emit(
            "run.resumed",
            {
                "revalidation_ok": True,
                "findings": [
                    finding.model_dump(mode="json")
                    for finding in revalidation.findings
                ],
                "resumed_tasks": list(resumed_tasks),
                "fresh_leases": list(completed_leases),
                "released_tasks": list(released),
            },
            now,
        )
        return ResumeOutcome(
            run_id=self.run_id,
            revalidation=revalidation,
            fresh_leases=tuple(fresh_leases),
            released=tuple(released),
            resumed=resumed_tasks,
        )

    # -- internals -------------------------------------------------------------

    def _reservation_universe(self) -> tuple[str, ...]:
        """Every task currently holding money or rate bookings."""
        return tuple(
            sorted(set(self.budget.reservations) | set(self.rate.reservations))
        )

    def _release_reservation(self, task_id: str) -> None:
        if task_id in self.budget.reservations:
            self.budget.release(task_id)
        if task_id in self.rate.reservations:
            self.rate.release(task_id)

    def _rollback_resume(
        self,
        fresh_leases: Sequence[Lease],
        started_clocks: Sequence[str],
        restored_resources: Sequence[str],
        now: datetime,
    ) -> dict[str, list[str]]:
        """Roll back every effect of a failed resume (best effort, fail closed).

        Every effect of the aborted mutation phase is reverted so the next
        resume starts from the clean pause state: the minted leases are
        fenced (a live lease under a PAUSED run would wedge the next claim),
        the started clocks are refrozen (the budget continues from the pause
        checkpoint) and the restored resources are re-frozen (the checkpoint
        still records them frozen). Returns the applied-cleanup report for
        the persisted ``run.resume_failed`` audit event.
        """
        fenced_lease_ids: list[str] = []
        for lease in fresh_leases:
            try:
                self.leases.fence(lease.lease_id)
                fenced_lease_ids.append(lease.lease_id)
            except Exception:
                pass  # an unfenceable ledger is already broken; the audit event records it
        refrozen_clocks: list[str] = []
        for task_id in started_clocks:
            try:
                self.clocks[task_id].freeze(now)
                refrozen_clocks.append(task_id)
            except Exception:
                pass
        refrozen_resources: list[str] = []
        for task_id in restored_resources:
            try:
                if (
                    self._resources is not None
                    and self._resources.freeze_authorized(task_id)
                ):
                    self._resources.freeze(task_id)
                    refrozen_resources.append(task_id)
            except Exception:
                pass
        return {
            "fenced_lease_ids": fenced_lease_ids,
            "refrozen_clocks": refrozen_clocks,
            "refrozen_resources": refrozen_resources,
        }

    def _running_lease(self, task_id: str, now: datetime) -> Lease | None:
        """The task's live lease at ``now`` (``None`` = not in flight)."""
        current = self.leases.current_lease(task_id)
        if current is None or not self.leases.lease_is_live(
            current.lease_id, self.run_id, now=now
        ):
            return None
        return current

    def _fence_if_live(self, task_id: str, now: datetime) -> bool:
        """Fence the task's live lease; ``True`` when the fence applied."""
        current = self._running_lease(task_id, now)
        if current is None:
            return False
        self.leases.fence(current.lease_id)
        return True

    def _load_checkpoint(self) -> PauseCheckpoint | None:
        """The latest persisted ``run.paused`` checkpoint (or ``None``)."""
        events = self.store.list_events(self.run_id)
        for event in reversed(events):
            if event.kind == "run.paused":
                return PauseCheckpoint.model_validate(event.payload)
        return None

    def _emit(self, kind: str, payload: dict, at: datetime) -> None:
        """Persist one durable run event (same table as every runtime event)."""
        event = RunEvent(run_id=self.run_id, kind=kind, at=at, payload=payload)
        with self.store.conn:
            self.store.conn.execute(
                "INSERT INTO events (run_id, kind, at, payload_json)"
                " VALUES (?, ?, ?, ?)",
                (
                    event.run_id,
                    event.kind,
                    event.at.isoformat(),
                    json.dumps(event.payload, sort_keys=True),
                ),
            )
