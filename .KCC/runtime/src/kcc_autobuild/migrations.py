"""Migration journal / target-authoritative resume.

Plan 05, Task 2 (Migration journal / target-authoritative resume): a
database migration that was interrupted must resume from the *target
system's* truth, never from KCC's belief about the attempt. Spec 14.6 /
22: durable state -- lifecycle state, task status, completed commits,
evidence -- is the source of truth over conversational memory, and
*completed tasks must not be re-dispatched solely because agent/session
context was lost*; spec 14.3 authorizes *database migration within the
approved destructive-action policy*, and the global contract requires
every external/data-mutation operation (deploy, migration, rollback) to
route through ``PolicyToolGate.call(Operation(...), args)`` -- DENIED
never calls the executor; AMBIGUOUS raises back to KCC machine
interpretation (never a direct user prompt; ruling R10: no extra
approval gates).

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_migrations.py`:

- :class:`MigrationStep` is the immutable identity of one migration:
  its ``id``, the ``target_version`` it moves the schema to, the
  ``idempotency_key`` that makes re-application detectable, and the
  policy triple ``resource`` / ``data_class`` the mutation must be
  classified under.
- :class:`MigrationAdapter` is the target-system view (duck-typed, no
  raw client): ``current_version`` (durable schema version, ``None`` for
  a fresh target), ``journal_contains`` (whether the applied-steps
  journal already records the step's id or idempotency key),
  ``execute_mutation`` (the raw mutation, invoked ONLY by the gate's
  executor -- never handed to the coordinator) and ``validate`` (re-check
  the target after an apply).
- :class:`MigrationCoordinator` is the pure decision + routing function
  for one step:
  - **target version already reached** OR **journal already contains the
    step** => :class:`MigrationOutcome.VALIDATE_ONLY` with NO apply:
    no mutation, no policy gate call. This is the commit-then-crash path:
    the target already reports v2 while KCC's durable run still says the
    step is in progress, so the resumed run must not re-apply.
  - otherwise the mutation routes through ``gate.call(Operation(
    operation="db.migrate", resource=..., data_class=...), args)`` with
    ``step_id`` / ``target_version`` / ``idempotency_key`` -- the ONLY
    external/data-mutation executor path; then the target is re-validated
    and a failed validation raises
    :class:`MigrationValidationError` instead of reporting APPLIED.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, Mapping, Protocol, runtime_checkable

from kcc_autobuild.policy import Operation

MIGRATION_OPERATION = "db.migrate"
"""Canonical policy verb for database migration (spec 14.3)."""


def _require_nonempty_text(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a str, got {type(value).__name__}")
    if not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value


@dataclass(frozen=True)
class MigrationStep:
    """One migration step, immutably identified for resume.

    ``id`` is the step's stable identity (e.g. ``migrate-0002``),
    ``target_version`` the schema version it moves the target to,
    ``idempotency_key`` the key that makes a re-application detectable --
    the journal records both, so a crash after the commit but before the
    journal write is still recognized by the target version. ``resource``
    and ``data_class`` are the exact policy triple the mutation operation
    is classified under (spec 24: no wildcards, no empty targets).
    """

    id: str
    target_version: str
    idempotency_key: str
    resource: str
    data_class: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "id", _require_nonempty_text(self.id, "id"))
        object.__setattr__(
            self,
            "target_version",
            _require_nonempty_text(self.target_version, "target_version"),
        )
        object.__setattr__(
            self,
            "idempotency_key",
            _require_nonempty_text(self.idempotency_key, "idempotency_key"),
        )
        object.__setattr__(
            self, "resource", _require_nonempty_text(self.resource, "resource")
        )
        object.__setattr__(
            self, "data_class", _require_nonempty_text(self.data_class, "data_class")
        )


class MigrationOutcome(str, Enum):
    """The resolved outcome of one migration step.

    ``VALIDATE_ONLY`` -- the target already proves the step done (version
    reached or journal recorded): completed work is never re-applied.
    ``APPLIED`` -- the mutation was routed through the policy gate, the
    target re-validated and the step is done.
    """

    VALIDATE_ONLY = "VALIDATE_ONLY"
    APPLIED = "APPLIED"


@dataclass(frozen=True)
class MigrationResult:
    """The outcome of one migration step, correlated with its step."""

    step: MigrationStep
    outcome: MigrationOutcome

    def __post_init__(self) -> None:
        if not isinstance(self.step, MigrationStep):
            raise TypeError(
                f"step must be a MigrationStep, got {type(self.step).__name__}"
            )
        if not isinstance(self.outcome, MigrationOutcome):
            raise TypeError(
                f"outcome must be a MigrationOutcome, got {type(self.outcome).__name__}"
            )


class MigrationError(RuntimeError):
    """Base class for migration failures (fail closed: never silently skip)."""


class MigrationValidationError(MigrationError):
    """The mutation ran (or was routed) but the target did not validate.

    Raised INSTEAD of reporting APPLIED: the target-system truth is
    authoritative, so a step whose target cannot be re-verified is never
    reported as applied -- the controller classifies it (e.g. BUG/DATA)
    rather than continuing on an unverifiable claim.
    """

    def __init__(self, step: MigrationStep, reason: str) -> None:
        self.step = step
        super().__init__(
            f"migration step {step.id!r} failed target validation after "
            f"mutation: {reason}"
        )


@runtime_checkable
class MigrationAdapter(Protocol):
    """Duck-typed target-system view for migration resume.

    The adapter NEVER holds a policy decision authority: it only reports
    target truth (``current_version`` / ``journal_contains`` /
    ``validate``) and performs the raw mutation
    (``execute_mutation``), which is invoked exclusively by the policy
    gate's executor -- never by the coordinator, never directly by
    KCC. ``execute_mutation`` receives the gate's unique policy decision
    token so the external call is correlated with its audit record.
    """

    def current_version(self) -> str | None:
        """The durable schema version of the target (``None`` = fresh)."""
        ...

    def journal_contains(self, step: MigrationStep) -> bool:
        """Whether the applied-steps journal already records ``step``."""
        ...

    def execute_mutation(self, step: MigrationStep, token: str) -> None:
        """Perform the raw mutation; called ONLY by the gate's executor."""
        ...

    def validate(self, step: MigrationStep) -> bool:
        """Re-verify the target reached ``step.target_version``."""
        ...


class MigrationGate(Protocol):
    """The only mutation entry the coordinator may use.

    One ``call(operation, args)`` for one requested operation: operations
    are evaluated and audited by the policy gate before the mutation
    executes (ALLOWED exactly once), DENIED never executes, and
    AMBIGUOUS raises back to KCC machine interpretation -- never a direct
    user prompt. The raw client stays inside the gate.
    """

    def call(
        self, operation: Operation, args: Mapping[str, object]
    ) -> Any:
        """Route one policy-classified operation with its step context."""
        ...


class MigrationCoordinator:
    """Decision + routing function for one migration step.

    Pure in behavior: no I/O, no wall clock; every decision comes from
    the injected :class:`MigrationAdapter` (target truth) and every
    mutation goes through the injected :class:`MigrationGate`.
    """

    def __init__(self, adapter: MigrationAdapter, gate: MigrationGate) -> None:
        if not isinstance(adapter, MigrationAdapter):
            raise TypeError(
                f"adapter must be a MigrationAdapter, got {type(adapter).__name__}"
            )
        if not callable(getattr(gate, "call", None)):
            raise TypeError(
                "gate must provide call(operation, args) -- the ONLY "
                "external/data-mutation executor path; a raw client is not "
                f"a gate ({type(gate).__name__})"
            )
        self._adapter = adapter
        self._gate = gate

    def apply(self, step: MigrationStep) -> MigrationResult:
        """Resolve ONE migration step against target-system truth.

        Target truth wins (spec 22; commit-then-crash): if the target
        version is already reached or the journal already contains the
        step the result is ``VALIDATE_ONLY`` and nothing -- not the
        mutation, not even a gate call -- happens. Otherwise the
        mutation is routed through ``gate.call(Operation(
        operation="db.migrate", resource=..., data_class=...), args)``
        and the target is re-validated: APPLIED only on a verified
        target, :class:`MigrationValidationError` otherwise.
        """
        if not isinstance(step, MigrationStep):
            raise TypeError(
                f"step must be a MigrationStep, got {type(step).__name__}"
            )

        if self._adapter.current_version() == step.target_version:
            return MigrationResult(step, MigrationOutcome.VALIDATE_ONLY)
        if self._adapter.journal_contains(step):
            return MigrationResult(step, MigrationOutcome.VALIDATE_ONLY)

        operation = Operation(
            operation=MIGRATION_OPERATION,
            resource=step.resource,
            data_class=step.data_class,
        )
        args: dict[str, object] = {
            "step_id": step.id,
            "target_version": step.target_version,
            "idempotency_key": step.idempotency_key,
        }
        self._gate.call(operation, args)

        if not self._adapter.validate(step):
            raise MigrationValidationError(
                step,
                f"target did not reach {step.target_version!r}",
            )
        return MigrationResult(step, MigrationOutcome.APPLIED)
