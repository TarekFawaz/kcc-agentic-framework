"""Deterministic FakeWorld for the autobuild 30-scenario evaluation.

Plan 07, Task 2 (``### Task 2: Deterministic FakeWorld`` of the local
Plan07 task contracts, plus its ## Global Constraints and the approved
Design Spec v1.2 section 27).

The FakeWorld is the single deterministic stand-in for every exogenous
system the control plane observes: the LLM provider (billing, rate
limits, outages), the CI runner, the extension store, the migration
target, the execution workers and the clock itself.  The scenario
runner (Task 3) wires the *real* controller to this world and drives it
over the 30 approved scenarios, then asserts the lifecycle state the
controller settles in.

Design guarantees (encoded in
:file:`.KCC/runtime/tests/test_evaluation_fake_world.py`):

* **Deterministic fake clock only, no sleep.**  ``now`` starts at
  :data:`DEFAULT_EPOCH` and only moves by ``advance()``; nothing reads
  the wall clock, no random/UUID state exists and no generator sleeps.
  Two worlds driven by the same script produce byte-identical event
  histories and reports.
* **Explicit injection surface.**  ``inject(flag, **params)`` is the
  *only* way a scenario changes the world, so behavior can never be
  inferred from an English scenario title (evaluation fidelity
  constraint).  Recognized flags: ``store_approval``,
  ``store_rejection``, ``worker_partition``,
  ``migration_commit_before_crash``, ``billing_lag``, ``ci_outage``
  (contract-required) plus the provider-fault flags
  ``provider_rate_limit`` and ``provider_outage`` used by the outage /
  rate scenarios.  Unknown flags or parameters are rejected before any
  state changes (fail closed).
* **Real runtime models.**  ``emit_report()`` builds and validates the
  real :class:`kcc_autobuild.bridge.ExecutionReport` model, so a
  fake worker can never produce a report the production schema would
  reject; ``provider_call()`` records real :class:`UsageInfo` billing
  records; a passed report without acceptance evidence or a failed
  report without a classified failure raises the production
  :class:`~pydantic.ValidationError`.
* **Event history.**  Every action (clock ticks, injections, provider
  calls, CI verification, report emissions, crashes, store submissions,
  migration commits) is recorded as a frozen :class:`WorldEvent` with a
  monotonic ``seq``, the fake ``at`` time and a JSON-serializable
  ``payload`` -- the durable deterministic trace a scenario run is
  compared against.

The world never hardcodes scenario outcomes: the controller -- not the
world -- decides the final state.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_evaluation_fake_world.py`.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from pydantic import ConfigDict

from kcc_autobuild.bridge import (
    AcceptanceEvidence,
    ExecutionReport,
    ExecutionStatus,
    FailureInfo,
    OutputInfo,
    UsageInfo,
)
from kcc_autobuild.models import StrictModel

# ---------------------------------------------------------------------------
# Deterministic identities / constants
# ---------------------------------------------------------------------------

DEFAULT_EPOCH = datetime(2026, 1, 1, tzinfo=timezone.utc)
"""Fixed deterministic start instant of every FakeWorld (aware UTC)."""

DEFAULT_TICK = timedelta(seconds=60)
"""Default step of a parameterless ``advance()`` call."""

DEFAULT_BILLING_LAG_SECONDS = 3600.0
DEFAULT_CI_OUTAGE_SECONDS = 3600.0
DEFAULT_RATE_LIMIT_SECONDS = 60.0
DEFAULT_PROVIDER_OUTAGE_SECONDS = 3600.0
DEFAULT_STORE_REJECTION_REASON = "submission rejected by store review"
DEFAULT_TOKENS_PER_CALL = 1000
COST_PER_1K_TOKENS_USD = 0.01

INJECTION_FLAGS: frozenset[str] = frozenset(
    {
        "store_approval",
        "store_rejection",
        "worker_partition",
        "migration_commit_before_crash",
        "billing_lag",
        "ci_outage",
        "provider_rate_limit",
        "provider_outage",
    }
)
"""The explicit injection surface: the only way scenarios mutate the world."""


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class FakeWorldError(ValueError):
    """Base class for rejected FakeWorld operations."""


class ClockError(FakeWorldError):
    """Raised when a fake-clock operation would move time backwards or is
    not deterministic (naive datetimes, nonpositive steps, mixed orders)."""


class UnknownInjectionFlag(FakeWorldError):
    """Raised when ``inject`` is given a flag outside :data:`INJECTION_FLAGS`."""


class InvalidInjection(FakeWorldError):
    """Raised when an injection flag carries missing or malformed parameters."""


class MigrationCrashError(RuntimeError):
    """The world simulated a post-commit migration crash.

    ``result`` carries the migration's outcome: the migration **was**
    committed to the target system before the crash (target truth), so a
    resume must recover from ``world.target_state`` and never re-apply,
    and must not trust pretender local state.
    """

    def __init__(self, result: MigrationResult) -> None:
        self.result = result
        super().__init__(
            f"migration {result.migration!r} committed to target then crashed"
        )


# ---------------------------------------------------------------------------
# Models (frozen, deterministic)
# ---------------------------------------------------------------------------


class WorldEvent(StrictModel):
    """One deterministic world event.

    ``seq`` is the world's monotonic event number, ``at`` the fake clock
    time the event happened and ``payload`` the JSON-serializable event
    detail.  Events are frozen: the history is a run's immutable trace.
    """

    model_config = ConfigDict(frozen=True)

    seq: int
    at: datetime
    kind: str
    payload: dict[str, Any]


class ProviderCallResult(StrictModel):
    """Outcome of one provider invocation as the controller observes it."""

    model_config = ConfigDict(frozen=True)

    call_id: str
    provider_key: str
    ok: bool
    status: str  # "ok" | "rate_limited" | "outage"
    usage: UsageInfo | None = None
    retry_after: float | None = None
    at: datetime


class CIResult(StrictModel):
    """Outcome of one CI verification as the controller observes it."""

    model_config = ConfigDict(frozen=True)

    check_id: str
    ref: str | None
    status: str  # "passed" | "outage"
    at: datetime


class StoreDecision(StrictModel):
    """The external store's decision on a submission."""

    model_config = ConfigDict(frozen=True)

    submission_id: str
    at: datetime
    status: str  # "approved" | "rejected"
    reasons: tuple[str, ...] = ()
    submission: str | None = None


class MigrationResult(StrictModel):
    """Outcome of one migration against the target system."""

    model_config = ConfigDict(frozen=True)

    migration_id: str
    at: datetime
    migration: str
    committed: bool
    crashed_after_commit: bool
    target_revision: int


class BillingRecord(StrictModel):
    """One provider usage record as the provider's ledger sees it.

    ``effective_at`` is the time the provider counts the usage
    (``at + billing lag`` when lag is injected): until the fake clock
    reaches ``effective_at`` the record is pending and is not returned by
    :meth:`FakeWorld.provider_actuals`.
    """

    model_config = ConfigDict(frozen=True)

    record_id: str
    provider_key: str
    usage: UsageInfo
    effective_at: datetime
    at: datetime


# ---------------------------------------------------------------------------
# Injection parameter validation (fail closed before any state change)
# ---------------------------------------------------------------------------


def _reject_unknown(params: Mapping[str, Any], allowed: tuple[str, ...]) -> None:
    unknown = sorted(set(params) - set(allowed))
    if unknown:
        raise InvalidInjection(f"unexpected parameter(s): {unknown}")


def _require_nonempty(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InvalidInjection(f"{name} must be a non-empty string")
    return value


def _positive_seconds(value: Any, name: str, default: float) -> float:
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidInjection(f"{name} must be a positive number")
    if value <= 0:
        raise InvalidInjection(f"{name} must be a positive number")
    return float(value)


def _nonnegative_int(value: Any, name: str, default: int) -> int:
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, int):
        raise InvalidInjection(f"{name} must be a non-negative integer")
    if value < 0:
        raise InvalidInjection(f"{name} must be a non-negative integer")
    return value


def _nonempty_optional(value: Any, name: str) -> str | None:
    if value is None:
        return None
    return _require_nonempty(value, name)


def _validate_store_approval(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ())
    return {}


def _validate_store_rejection(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ("reason",))
    reason = _require_nonempty(
        params.get("reason", DEFAULT_STORE_REJECTION_REASON), "reason"
    )
    return {"reason": reason}


def _validate_worker_partition(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ("task_id", "wave"))
    task_id = _require_nonempty(params.get("task_id"), "task_id")
    wave = _nonempty_optional(params.get("wave"), "wave")
    return {"task_id": task_id, "wave": wave}


def _validate_migration_crash(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ("migration",))
    migration = _nonempty_optional(params.get("migration"), "migration")
    return {"migration": migration}


def _validate_billing_lag(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ("seconds",))
    seconds = _positive_seconds(
        params.get("seconds"), "seconds", DEFAULT_BILLING_LAG_SECONDS
    )
    return {"seconds": seconds}


def _validate_ci_outage(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ("seconds",))
    seconds = _positive_seconds(
        params.get("seconds"), "seconds", DEFAULT_CI_OUTAGE_SECONDS
    )
    return {"seconds": seconds}


def _validate_provider_rate_limit(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ("provider_key", "after_calls", "seconds"))
    provider_key = _require_nonempty(params.get("provider_key"), "provider_key")
    after_calls = _nonnegative_int(params.get("after_calls"), "after_calls", 0)
    seconds = _positive_seconds(
        params.get("seconds"), "seconds", DEFAULT_RATE_LIMIT_SECONDS
    )
    return {
        "provider_key": provider_key,
        "after_calls": after_calls,
        "seconds": seconds,
    }


def _validate_provider_outage(params: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(params, ("provider_key", "seconds"))
    provider_key = _require_nonempty(params.get("provider_key"), "provider_key")
    seconds = _positive_seconds(
        params.get("seconds"), "seconds", DEFAULT_PROVIDER_OUTAGE_SECONDS
    )
    return {"provider_key": provider_key, "seconds": seconds}


_INJECTION_VALIDATORS: dict[str, Callable[[Mapping[str, Any]], dict[str, Any]]] = {
    "store_approval": _validate_store_approval,
    "store_rejection": _validate_store_rejection,
    "worker_partition": _validate_worker_partition,
    "migration_commit_before_crash": _validate_migration_crash,
    "billing_lag": _validate_billing_lag,
    "ci_outage": _validate_ci_outage,
    "provider_rate_limit": _validate_provider_rate_limit,
    "provider_outage": _validate_provider_outage,
}


def _as_model(value: Any, model: type) -> Any:
    """Accept an instance or a dict; the real model validates both."""
    if isinstance(value, model):
        return value
    return model(**value)


def _as_model_list(values: list[Any] | None, model: type) -> list[Any]:
    return [_as_model(value, model) for value in (values or [])]


# ---------------------------------------------------------------------------
# FakeWorld
# ---------------------------------------------------------------------------


class FakeWorld:
    """Deterministic stand-in for every exogenous system of an autobuild run.

    The world is created at :data:`DEFAULT_EPOCH` (or an explicit aware
    ``epoch``) and only advances through :meth:`advance`, so a script of
    calls is a reproducible experiment.  Every call is recorded in the
    immutable :attr:`events` history; no wall clock, no random, no sleep.
    """

    def __init__(self, *, epoch: datetime | None = None) -> None:
        if epoch is None:
            self._now = DEFAULT_EPOCH
        elif epoch.tzinfo is None or epoch.utcoffset() is None:
            raise ValueError("epoch must be timezone-aware")
        else:
            self._now = epoch
        self._seq = 0
        self._events: list[WorldEvent] = []
        self._reports: list[ExecutionReport] = []
        self._billing: list[BillingRecord] = []
        self._target_state: list[str] = []
        # Provider state.
        self._provider_invocations: dict[str, int] = {}
        self._rate_limits: dict[str, tuple[int, datetime]] = {}
        self._provider_outages: dict[str, datetime] = {}
        # External systems state.
        self._ci_outage_until: datetime | None = None
        self._store_rejection_reasons: tuple[str, ...] | None = None
        self._billing_lag = timedelta(0)
        # One-shot fault arming.
        self._partitioned: dict[str, dict[str, Any]] = {}
        self._migration_crash_armed: dict[str, bool] = {}
        # Sequence counters (deterministic ids).
        self._call_counter = 0
        self._check_counter = 0
        self._report_counter = 0
        self._store_counter = 0
        self._migration_counter = 0
        self._billing_counter = 0

    # -- deterministic clock -------------------------------------------------

    @property
    def now(self) -> datetime:
        """Current fake time (aware UTC); only :meth:`advance` moves it."""
        return self._now

    def advance(
        self,
        *,
        seconds: float | None = None,
        to: datetime | None = None,
    ) -> datetime:
        """Advance the fake clock deterministically and return the new time.

        Call with ``seconds`` (positive), with ``to`` (an aware instant
        strictly after now) or with neither for a default
        :data:`DEFAULT_TICK`.  Backwards, nonpositive or naive movements
        are rejected and leave the clock untouched (no event is recorded).
        """
        if seconds is not None and to is not None:
            raise ClockError("pass seconds or to, not both")
        if to is not None:
            if to.tzinfo is None or to.utcoffset() is None:
                raise ClockError("to must be timezone-aware")
            if to <= self._now:
                raise ClockError("the fake clock never goes backwards")
            delta = to - self._now
        elif seconds is not None:
            try:
                delta = timedelta(seconds=_positive_seconds(seconds, "seconds", 0))
            except InvalidInjection as exc:
                raise ClockError(str(exc)) from None
            if delta <= timedelta(0):
                raise ClockError("the fake clock never goes backwards")
        else:
            delta = DEFAULT_TICK
        target = self._now + delta
        self._record(
            "clock.advance",
            {
                "from": self._now.isoformat(),
                "to": target.isoformat(),
                "seconds": delta.total_seconds(),
            },
        )
        self._now = target
        return self._now

    # -- injection -----------------------------------------------------------

    def inject(self, flag: str, **params: Any) -> WorldEvent:
        """Inject one deterministic world-fault flag and return its event.

        ``flag`` must be in :data:`INJECTION_FLAGS` and its parameters
        must satisfy the flag contract; otherwise
        :class:`FakeWorldError` is raised before any state changes.

        Contract flags: ``store_approval`` / ``store_rejection(reason=)``
        (scenario 30), ``worker_partition(task_id=, wave=)`` (scenarios
        13/19), ``migration_commit_before_crash(migration=)`` (scenario
        23), ``billing_lag(seconds=)`` (scenario 22), ``ci_outage(seconds=)``
        (scenario 24); plus ``provider_rate_limit(provider_key=,
        after_calls=, seconds=)`` and ``provider_outage(provider_key=,
        seconds=)`` for the provider-fault scenarios.
        """
        validator = _INJECTION_VALIDATORS.get(flag)
        if validator is None:
            raise UnknownInjectionFlag(f"unknown injection flag {flag!r}")
        normalized = validator(params)
        payload = {"flag": flag, **normalized}

        if flag == "store_approval":
            self._store_rejection_reasons = None
        elif flag == "store_rejection":
            self._store_rejection_reasons = (normalized["reason"],)
        elif flag == "worker_partition":
            self._partitioned[normalized["task_id"]] = {
                "wave": normalized["wave"],
            }
        elif flag == "migration_commit_before_crash":
            migration = normalized["migration"]
            self._migration_crash_armed["*" if migration is None else migration] = True
        elif flag == "billing_lag":
            self._billing_lag = timedelta(seconds=normalized["seconds"])
        elif flag == "ci_outage":
            self._ci_outage_until = self._now + timedelta(
                seconds=normalized["seconds"]
            )
        elif flag == "provider_rate_limit":
            self._rate_limits[normalized["provider_key"]] = (
                normalized["after_calls"],
                self._now + timedelta(seconds=normalized["seconds"]),
            )
        elif flag == "provider_outage":
            self._provider_outages[normalized["provider_key"]] = self._now + timedelta(
                seconds=normalized["seconds"]
            )
        return self._record("inject", payload)

    # -- provider ------------------------------------------------------------

    def provider_call(
        self, provider_key: str, *, max_tokens: int | None = None
    ) -> ProviderCallResult:
        """Simulate one LLM provider invocation.

        Success charges the deterministic usage (``DEFAULT_TOKENS_PER_CALL``
        tokens at ``COST_PER_1K_TOKENS_USD`` per 1k, ``max_tokens``
        scales it) and records a :class:`BillingRecord` whose
        ``effective_at`` includes any injected billing lag.  Injected
        rate limits (``after_calls`` succeeded invocations, then
        ``rate_limited`` with ``retry_after``) and outages return
        ``ok=False`` without charging usage.
        """
        provider_key = _require_nonempty(provider_key, "provider_key")
        if max_tokens is not None and (
            isinstance(max_tokens, bool)
            or not isinstance(max_tokens, int)
            or max_tokens < 1
        ):
            raise ValueError("max_tokens must be a positive integer")

        self._call_counter += 1
        call_id = f"call-{self._call_counter}"
        invocations = self._provider_invocations.get(provider_key, 0) + 1
        self._provider_invocations[provider_key] = invocations
        at = self._now

        outage_until = self._provider_outages.get(provider_key)
        if outage_until is not None and at < outage_until:
            result = ProviderCallResult(
                call_id=call_id,
                provider_key=provider_key,
                ok=False,
                status="outage",
                usage=None,
                retry_after=None,
                at=at,
            )
            self._record(
                "provider.call",
                {
                    "call_id": call_id,
                    "provider_key": provider_key,
                    "status": "outage",
                    "invocations": invocations,
                },
            )
            return result

        rate_limit = self._rate_limits.get(provider_key)
        if rate_limit is not None:
            after_calls, retry_until = rate_limit
            if invocations > after_calls and at < retry_until:
                result = ProviderCallResult(
                    call_id=call_id,
                    provider_key=provider_key,
                    ok=False,
                    status="rate_limited",
                    usage=None,
                    retry_after=(retry_until - at).total_seconds(),
                    at=at,
                )
                self._record(
                    "provider.call",
                    {
                        "call_id": call_id,
                        "provider_key": provider_key,
                        "status": "rate_limited",
                        "invocations": invocations,
                        "retry_after": result.retry_after,
                    },
                )
                return result

        tokens = DEFAULT_TOKENS_PER_CALL if max_tokens is None else max_tokens
        cost_usd = float(tokens) / 1000.0 * COST_PER_1K_TOKENS_USD
        usage = UsageInfo(
            tokens=tokens,
            cost_usd=cost_usd,
            provider_calls=1,
        )
        self._billing_counter += 1
        self._billing.append(
            BillingRecord(
                record_id=f"bill-{self._billing_counter}",
                provider_key=provider_key,
                usage=usage,
                effective_at=at + self._billing_lag,
                at=at,
            )
        )
        result = ProviderCallResult(
            call_id=call_id,
            provider_key=provider_key,
            ok=True,
            status="ok",
            usage=usage,
            retry_after=None,
            at=at,
        )
        self._record(
            "provider.call",
            {
                "call_id": call_id,
                "provider_key": provider_key,
                "status": "ok",
                "invocations": invocations,
                "tokens": tokens,
                "cost_usd": cost_usd,
            },
        )
        return result

    # -- billing -------------------------------------------------------------

    @property
    def billing(self) -> tuple[BillingRecord, ...]:
        """Every provider usage record (settled and pending), in order."""
        return tuple(self._billing)

    def provider_actuals(self, provider_key: str | None = None) -> tuple[UsageInfo, ...]:
        """Provider truth: usage the provider has actually settled by now.

        With an injected billing lag a record stays invisible until the
        fake clock reaches its ``effective_at``; the control plane must
        reconcile against this truth, never against claimed usage.
        """
        return tuple(
            record.usage
            for record in self._billing
            if record.effective_at <= self._now
            and (provider_key is None or record.provider_key == provider_key)
        )

    # -- CI ------------------------------------------------------------------

    def ci_verify(self, ref: str | None = None) -> CIResult:
        """Verify a CI evidence ref against the world's CI runner state."""
        if ref is not None:
            _require_nonempty(ref, "ref")
        self._check_counter += 1
        check_id = f"ci-{self._check_counter}"
        at = self._now
        if self._ci_outage_until is not None and at < self._ci_outage_until:
            status = "outage"
        else:
            status = "passed"
        self._record(
            "ci.verify",
            {"check_id": check_id, "ref": ref, "status": status},
        )
        return CIResult(
            check_id=check_id, ref=ref, status=status, at=at
        )

    # -- execution reports ---------------------------------------------------

    def emit_report(
        self,
        *,
        run_id: str,
        task_id: str,
        attempt: int,
        status: ExecutionStatus | str,
        lease_id: str | None = None,
        workspace_id: str | None = None,
        acceptance_evidence: list[AcceptanceEvidence | dict] | None = None,
        failure: FailureInfo | dict | None = None,
        usage: UsageInfo | dict | None = None,
        outputs: list[OutputInfo | dict] | None = None,
        deviations: list[str] | None = None,
        trace_updates: list[str] | None = None,
    ) -> ExecutionReport | None:
        """Emit a worker's terminal Execution Report (real runtime model).

        A ``worker_partition`` injection makes the first report for that
        task crash instead of arriving (returns ``None`` and records a
        ``worker.partition`` event); the one-shot fault is consumed, so a
        fresh worker's retry is delivered normally.

        The returned report is a genuine
        :class:`kcc_autobuild.bridge.ExecutionReport`: a passed report
        without acceptance evidence or a failed/blocked report without a
        classified failure raises the production validation error, so a
        false-pass or unclassified report can never enter world history.
        """
        partition = self._partitioned.pop(task_id, None)
        if partition is not None:
            return self._record_partition(task_id, run_id, attempt, partition)

        if lease_id is None:
            lease_id = f"lease-{run_id}-{task_id}-{attempt}"
        if workspace_id is None:
            workspace_id = f"workspace-{run_id}-{task_id}-{attempt}"
        report = ExecutionReport(
            run_id=run_id,
            task_id=task_id,
            attempt=attempt,
            status=status,
            lease_id=lease_id,
            workspace_id=workspace_id,
            acceptance_evidence=_as_model_list(acceptance_evidence, AcceptanceEvidence),
            failure=_as_model(failure, FailureInfo) if failure is not None else None,
            usage=_as_model(usage, UsageInfo) if usage is not None else UsageInfo(),
            outputs=_as_model_list(outputs, OutputInfo),
            deviations=deviations or [],
            trace_updates=trace_updates or [],
        )
        self._report_counter += 1
        report_id = f"report-{self._report_counter}"
        self._reports.append(report)
        self._record(
            "report.emit",
            {
                "report_id": report_id,
                "run_id": run_id,
                "task_id": task_id,
                "attempt": attempt,
                "status": report.status.value,
                "lease_id": lease_id,
                "workspace_id": workspace_id,
            },
        )
        return report

    def _record_partition(
        self,
        task_id: str,
        run_id: str,
        attempt: int,
        partition: dict[str, Any],
    ) -> None:
        wave = partition.get("wave")
        self._record(
            "worker.partition",
            {
                "task_id": task_id,
                "run_id": run_id,
                "attempt": attempt,
                "wave": wave,
            },
        )
        return None

    # -- execution history ---------------------------------------------------

    @property
    def events(self) -> tuple[WorldEvent, ...]:
        """Immutable deterministic history of every world action, in order."""
        return tuple(self._events)

    @property
    def reports(self) -> tuple[ExecutionReport, ...]:
        """Every ExecutionReport that actually reached the world, in order."""
        return tuple(self._reports)

    def _record(self, kind: str, payload: dict[str, Any]) -> WorldEvent:
        self._seq += 1
        event = WorldEvent(seq=self._seq, at=self._now, kind=kind, payload=payload)
        self._events.append(event)
        return event

    # -- store ---------------------------------------------------------------

    def store_submit(self, submission: str | None = None) -> StoreDecision:
        """Submit to the external store and return its deterministic decision.

        The decision is ``approved`` unless a ``store_rejection``
        injection is the most recent store verdict (its reason rides along
        as the batched review decision for scenario 30); a later
        ``store_approval`` reverts the world to approving.
        """
        if submission is not None:
            _require_nonempty(submission, "submission")
        self._store_counter += 1
        submission_id = f"store-{self._store_counter}"
        at = self._now
        if self._store_rejection_reasons is None:
            status = "approved"
            reasons: tuple[str, ...] = ()
        else:
            status = "rejected"
            reasons = self._store_rejection_reasons
        self._record(
            "store.submit",
            {
                "submission_id": submission_id,
                "status": status,
                "reasons": list(reasons),
                "submission": submission,
            },
        )
        return StoreDecision(
            submission_id=submission_id,
            at=at,
            status=status,
            reasons=reasons,
            submission=submission,
        )

    # -- migration target ----------------------------------------------------

    @property
    def target_state(self) -> tuple[str, ...]:
        """TARGET-system truth: migrations committed on the target, in order.

        A ``migration_commit_before_crash`` injection commits here first
        and only then crashes the process, so resume truth lives here and
        never in local pretender state (scenario 23).
        """
        return tuple(self._target_state)

    @property
    def target_revision(self) -> int:
        """Monotonic revision number of the migration target."""
        return len(self._target_state)

    def migrate(self, name: str) -> MigrationResult:
        """Run one migration against the target system.

        With a ``migration_commit_before_crash`` injection armed (any
        migration, or only the named one) the migration commits to the
        target first and then the world crashes (raises
        :class:`MigrationCrashError`); the arming is one-shot.  Without
        arming the migration commits cleanly.
        """
        name = _require_nonempty(name, "migration")
        self._migration_counter += 1
        migration_id = f"migration-{self._migration_counter}"
        at = self._now
        armed = self._migration_crash_armed.pop("*", False)
        armed = self._migration_crash_armed.pop(name, False) or armed
        self._target_state.append(name)
        result = MigrationResult(
            migration_id=migration_id,
            at=at,
            migration=name,
            committed=True,
            crashed_after_commit=armed,
            target_revision=len(self._target_state),
        )
        self._record(
            "migration.commit_crash" if armed else "migration.commit",
            {
                "migration_id": migration_id,
                "migration": name,
                "target_revision": result.target_revision,
                "crashed": armed,
            },
        )
        if armed:
            raise MigrationCrashError(result)
        return result
