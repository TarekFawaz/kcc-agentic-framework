"""Policy tool gate: the ONLY external / data-mutation executor path.

Plan 04, Task 6 (Deterministic destructive-operation policy evaluator): the
runtime's provider, deploy and migration mutation adapters must never hold a
raw client -- they receive the already-policy-bound
:class:`PolicyToolGate`, which is the sole path from a requested mutation to
the executor that actually performs it. The controller/issuer side signs the
destructive-action policy (Design Spec v1.2 section 14.5) into a canonical
:class:`~kcc_autobuild.policy.PolicyBundle`; the gate evaluates every
:class:`~kcc_autobuild.policy.Operation` (spec section 24: destructive
operations must be policy-classified before execution) and only then acts.

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_tool_gate.py`:

- One :class:`PolicyAudit` is recorded -- with a **unique policy decision
  token** (UUID hex by default; injectable for deterministic tests) -- for
  every attempt, **before** the executor is invoked (audit first, then
  call), so no mutation can ever occur without a prior signed decision
  record. The audit trail is kept on :attr:`PolicyToolGate.audits` and an
  optional :class:`PolicyAuditSink` (e.g. the controller's Decision Log
  writer) is notified.
- ALLOWED (exact rule, verified signature) -> the wrapped executor is
  invoked exactly once with ``(operation, token)`` so the external call is
  correlated with its decision record.
- DENIED -> :class:`PolicyDenied` is raised and the executor is NEVER
  invoked (a denied mutation fails closed; the controller classifies it as
  a contract/policy failure).
- AMBIGUOUS (same operation, mismatched resource/data_class) ->
  :class:`AmbiguousPolicy` is raised back to KCC machine interpretation:
  the exception carries the structured ``token`` / ``operation`` /
  ``decision`` fields so the controller can escalate through the spec 18
  E4 (irreversible/ambiguous action outside approved policy) exception path
  -- it is never a direct user prompt (spec section 4.5 notifications-not-
  approvals; ruling R10: no extra approval gates), and the executor is NEVER
  invoked.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any, Callable, Protocol

from kcc_autobuild.policy import Operation, PolicyDecision, PolicyEvaluator


class PolicyGateError(RuntimeError):
    """Base class for gate-raised policy refusals.

    ``token`` is the unique policy decision token already recorded in the
    audit trail, ``operation`` the refused operation and ``decision`` the
    evaluator verdict -- all machine-readable, so the controller can
    interpret and classify (CONTRACT) the refusal without asking the user.
    """

    def __init__(
        self,
        token: str,
        operation: Operation,
        decision: PolicyDecision,
        message: str,
    ) -> None:
        self.token = token
        self.operation = operation
        self.decision = decision
        super().__init__(message)


class PolicyDenied(PolicyGateError):
    """The operation is exactly DENIED by the signed policy.

    Raised before the executor is ever invoked: the mutation never happens,
    the audit records DENIED, and the controller records the refusal (spec
    18/E4-adjacent contract failure) without retrying blindly.
    """

    def __init__(self, token: str, operation: Operation) -> None:
        super().__init__(
            token,
            operation,
            PolicyDecision.DENIED,
            (
                f"policy DENIED {operation.operation!r} on "
                f"{operation.resource!r} ({operation.data_class}) "
                f"[token {token}]"
            ),
        )


class AmbiguousPolicy(PolicyGateError):
    """The operation is AMBIGUOUS under the signed policy.

    Raised back to KCC machine interpretation -- a structured, machine-
    readable exception carrying ``token`` / ``operation`` / ``decision``
    (AMBIGUOUS) for the spec 18/E4 escalation path. It is NEVER a direct
    user prompt (spec 4.5; ruling R10: no extra approval gates), and the
    executor is never invoked.
    """

    def __init__(self, token: str, operation: Operation) -> None:
        super().__init__(
            token,
            operation,
            PolicyDecision.AMBIGUOUS,
            (
                f"policy AMBIGUOUS {operation.operation!r} on "
                f"{operation.resource!r} ({operation.data_class}) "
                f"[token {token}] -- escalate to KCC machine interpretation"
            ),
        )


@dataclass(frozen=True)
class PolicyAudit:
    """One policy decision record, written BEFORE any executor invocation.

    ``token`` is the unique decision token for this attempt (correlation
    key between audit record and the executor call it authorized), and
    ``operation`` / ``decision`` snapshot exactly what the gate decided.
    """

    token: str
    operation: Operation
    decision: PolicyDecision

    def __post_init__(self) -> None:
        if not isinstance(self.token, str) or not self.token:
            raise ValueError("policy audit token must be a non-empty string")
        if not isinstance(self.operation, Operation):
            raise TypeError(
                "policy audit operation must be an Operation, "
                f"got {type(self.operation).__name__}"
            )
        if not isinstance(self.decision, PolicyDecision):
            raise TypeError(
                "policy audit decision must be a PolicyDecision, "
                f"got {type(self.decision).__name__}"
            )


class PolicyAuditSink(Protocol):
    """Durable audit destination (duck-typed; e.g. the Decision Log writer).

    ``record`` is called with the :class:`PolicyAudit` before any executor
    invocation -- including DENIED and AMBIGUOUS refusals, which must be
    auditable too.
    """

    def record(self, audit: PolicyAudit) -> None:
        ...


class PolicyToolGate:
    """Gate one signed policy against one mutation executor.

    Constructor arguments:

    - ``evaluator``: the :class:`~kcc_autobuild.policy.PolicyEvaluator` for
      the verified bundle (rejected otherwise -- the gate never runs
      against an untrusted policy);
    - ``executor``: the single callable that performs the external/
      data-mutation work, invoked as ``executor(operation, token)`` ONLY
      on an ALLOWED decision (the raw client is bound here and never
      handed to adapters);
    - ``audit_sink`` (optional): destination for :class:`PolicyAudit`
      records; when omitted the in-memory :attr:`audits` trail is the log;
    - ``token_factory`` (optional): callable returning the unique decision
      token (default: ``uuid.uuid4().hex``).
    """

    def __init__(
        self,
        evaluator: PolicyEvaluator,
        executor: Callable[[Operation, str], Any],
        *,
        audit_sink: PolicyAuditSink | None = None,
        token_factory: Callable[[], str] | None = None,
    ) -> None:
        if not isinstance(evaluator, PolicyEvaluator):
            raise TypeError(
                "evaluator must be a PolicyEvaluator, "
                f"got {type(evaluator).__name__}"
            )
        if not callable(executor):
            raise TypeError(
                f"executor must be callable, got {type(executor).__name__}"
            )
        if audit_sink is not None and not callable(getattr(audit_sink, "record", None)):
            raise TypeError(
                "audit_sink must provide record(audit), "
                f"got {type(audit_sink).__name__}"
            )
        if token_factory is not None and not callable(token_factory):
            raise TypeError(
                "token_factory must be callable, "
                f"got {type(token_factory).__name__}"
            )
        self.evaluator = evaluator
        self._executor = executor
        self._sink = audit_sink
        self._token_factory = token_factory or (lambda: uuid.uuid4().hex)
        self.audits: list[PolicyAudit] = []

    def execute(self, operation: Operation) -> Any:
        """Evaluate, audit and (only if ALLOWED) execute ``operation``.

        The audit record is written before the executor is invoked: for
        ALLOWED the executor runs once and its result is returned; for
        DENIED :class:`PolicyDenied` is raised with the executor untouched;
        for AMBIGUOUS :class:`AmbiguousPolicy` is raised to KCC machine
        interpretation with the executor untouched.
        """
        if not isinstance(operation, Operation):
            raise TypeError(
                f"operation must be an Operation, got {type(operation).__name__}"
            )
        decision = self.evaluator.evaluate(operation)
        token = self._token_factory()
        audit = PolicyAudit(token=token, operation=operation, decision=decision)
        self.audits.append(audit)
        if self._sink is not None:
            self._sink.record(audit)
        if decision is PolicyDecision.ALLOWED:
            return self._executor(operation, token)
        if decision is PolicyDecision.DENIED:
            raise PolicyDenied(token, operation)
        raise AmbiguousPolicy(token, operation)
