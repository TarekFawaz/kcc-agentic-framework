"""Staging/production deployment + rollback contract.

Plan 05, Task 3 (Staging/production deployment + rollback contract): a
production deployment is an authorized, policy-classified external
data-mutation operation (spec 20: deployment only where authorized;
spec 14.5/24: destructive/mutating operations must be policy-classified
before execution), and the global contract requires every
external/data-mutation operation (deploy, migration, rollback) to route
through ``PolicyToolGate.call(Operation(...), args)`` -- DENIED never
calls the executor; AMBIGUOUS raises back to KCC machine interpretation
(never a direct user prompt; ruling R10: no extra approval gates).

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_deployment.py`:

- :class:`RolloutClass` is the canonical rollout vocabulary locked into
  the contract: ``CANARY`` (validate in production before full exposure)
  and ``DIRECT``. Only the LOCKED class may be used: an explicit
  ``requested_rollout`` that differs from the lock raises
  :class:`RolloutMismatchError` -- an attempt to overrule the lock fails
  closed before any gate call or mutation (the prescribed "direct
  rejected when canary locked" case).
- :class:`DeploymentAdapter` is the target-system view (duck-typed, no
  policy authority, no raw client handed to KCC): ``data_class`` is the
  data sensitivity classification of the production target,
  ``health(target)`` the post-deploy target truth (never KCC's belief),
  and ``deploy`` / ``rollback`` the raw mutations invoked exclusively by
  the gate's executor -- never by the coordinator.
- :class:`DeploymentCoordinator.deploy(contract, requested_rollout=None)`
  is the pure decision + routing function for one deployment:
  - the rollout class comes from the locked
    ``contract.tier1.rollout_class`` (``requested_rollout=None`` means:
    the lock decides);
  - the production target comes from ``contract.tier1.production_target``
    and is the exact policy RESOURCE of both operations;
  - the production deploy goes through ``gate.call(Operation(
    operation="deploy", resource=<production target>,
    data_class=<adapter.data_class>), args)`` with
    ``target`` / ``rollout_class``;
  - the adapter then reports health: healthy => :class:`DeploymentOutcome`
    ``DEPLOYED``; unhealthy => ONE rollback operation on the SAME target
    routed through the gate and :class:`DeploymentOutcome`
    ``ROLLED_BACK`` (the prescribed "canary health failure auto
    rollback" case).

A contract whose tier-1 lock is incomplete (no ``rollout_class``, no
non-empty ``production_target``) is refused -- nothing may be deployed
against an unlocked surface.
"""

from __future__ import annotations

from enum import Enum
from typing import Any, Mapping, Protocol, runtime_checkable

from kcc_autobuild.policy import Operation

DEPLOY_OPERATION = "deploy"
"""Canonical policy verb for the production deploy operation (spec 20.2)."""

ROLLBACK_OPERATION = "rollback"
"""Canonical policy verb for the rollback of the same production target."""


class RolloutClass(str, Enum):
    """The rollout class locked into the Build Contract (tier-1).

    ``CANARY`` -- deploy to production through a canary gate: the
    post-deploy health check decides between DEPLOYED and an immediate
    rollback. ``DIRECT`` -- expose directly to production (still
    health-checked; on failure the same rollback path applies).
    """

    CANARY = "CANARY"
    DIRECT = "DIRECT"


class DeploymentOutcome(str, Enum):
    """The resolved outcome of one deployment.

    ``DEPLOYED`` -- the deploy operation ran through the gate and the
    post-deploy health check passed. ``ROLLED_BACK`` -- the deploy ran,
    health failed, and one rollback operation on the same target was
    routed through the gate.
    """

    DEPLOYED = "DEPLOYED"
    ROLLED_BACK = "ROLLED_BACK"


def _require_nonempty_text(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a str, got {type(value).__name__}")
    if not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value


class DeploymentError(RuntimeError):
    """Base class for deployment refusals (fail closed)."""


class DeploymentContractError(DeploymentError):
    """The locked contract does not carry a usable deployment surface.

    Raised when ``tier1.rollout_class`` is missing/unrecognized or
    ``tier1.production_target`` is missing/blank: deployment never runs
    against an unlocked or incomplete lock, and no gate call or mutation
    happens.
    """


class RolloutMismatchError(DeploymentError):
    """An explicit rollout request differs from the locked class.

    ``locked`` / ``requested`` are the conflicting
    :class:`RolloutClass` values (machine-readable): the lock wins,
    nothing is deployed, and the controller can classify the refusal
    without asking the user.
    """

    def __init__(self, locked: RolloutClass, requested: RolloutClass) -> None:
        self.locked = locked
        self.requested = requested
        super().__init__(
            f"requested rollout {requested.value!r} differs from the locked "
            f"rollout class {locked.value!r}"
        )


@runtime_checkable
class DeploymentAdapter(Protocol):
    """Duck-typed target-system view for deployment.

    The adapter NEVER holds policy decision authority: it only reports
    target truth (``data_class`` classification, ``health``) and performs
    the raw mutations (``deploy`` / ``rollback``), which are invoked
    exclusively by the policy gate's executor -- never by the
    coordinator, never directly by KCC. Each mutation receives the gate's
    unique policy decision token so the external call is correlated with
    its audit record.
    """

    data_class: str
    """The data sensitivity classification of the production target."""

    def health(self, target: str) -> bool:
        """Truth of the post-deploy health check on ``target``."""
        ...

    def deploy(self, target: str, rollout: RolloutClass, token: str) -> None:
        """Perform the raw deploy mutation; called ONLY by the gate."""
        ...

    def rollback(self, target: str, token: str) -> None:
        """Perform the raw rollback mutation; called ONLY by the gate."""
        ...


class DeploymentGate(Protocol):
    """The only mutation entry the coordinator may use.

    One ``call(operation, args)`` for one requested operation:
    operations are evaluated and audited by the policy gate before the
    mutation executes (ALLOWED exactly once), DENIED never executes, and
    AMBIGUOUS raises back to KCC machine interpretation -- never a direct
    user prompt. The raw client stays inside the gate.
    """

    def call(
        self, operation: Operation, args: Mapping[str, object]
    ) -> Any:
        """Route one policy-classified operation with its context."""
        ...


def _coerce_rollout_class(value: object, name: str) -> RolloutClass:
    """Normalize a rolled class to :class:`RolloutClass`.

    Accepts the canonical enum member or its canonical string
    (``"CANARY"`` / ``"DIRECT"``); everything else is rejected -- an
    unrecognized class is never guessed.
    """
    if isinstance(value, RolloutClass):
        return value
    if isinstance(value, str):
        try:
            return RolloutClass(value.strip())
        except ValueError:
            raise ValueError(
                f"{name} must be a canonical rollout class, got {value!r}"
            ) from None
    raise TypeError(
        f"{name} must be a RolloutClass or its canonical string, "
        f"got {type(value).__name__}"
    )


class DeploymentCoordinator:
    """Decision + routing function for one production deployment.

    Pure in behavior: no I/O, no wall clock; every decision comes from
    the locked contract (rollout class + production target), the
    injected :class:`DeploymentAdapter` (target truth) and every
    mutation goes through the injected :class:`DeploymentGate`.
    """

    def __init__(self, adapter: DeploymentAdapter, gate: DeploymentGate) -> None:
        if not isinstance(adapter, DeploymentAdapter):
            raise TypeError(
                f"adapter must be a DeploymentAdapter, got {type(adapter).__name__}"
            )
        if not callable(getattr(gate, "call", None)):
            raise TypeError(
                "gate must provide call(operation, args) -- the ONLY "
                "external/data-mutation executor path; a raw client is not "
                f"a gate ({type(gate).__name__})"
            )
        self._adapter = adapter
        self._gate = gate

    def deploy(
        self,
        contract: Any,
        requested_rollout: RolloutClass | str | None = None,
    ) -> DeploymentOutcome:
        """Deploy to the locked production target, rollback on bad health.

        The locked ``contract.tier1.rollout_class`` decides the rollout
        (an explicit ``requested_rollout`` differing from it raises
        before anything happens). The production target is
        ``contract.tier1.production_target`` -- the exact policy resource
        of the deploy operation; after the deploy the adapter reports
        health: healthy => DEPLOYED, unhealthy => one rollback operation
        on the SAME target through the gate => ROLLED_BACK.
        """
        tier1 = getattr(contract, "tier1", None)
        if tier1 is None:
            raise DeploymentContractError(
                "deployment requires a locked contract carrying tier-1 "
                "invariants (contract.tier1)"
            )

        if not hasattr(tier1, "rollout_class"):
            raise DeploymentContractError(
                "deployment requires a locked rollout class "
                "(contract.tier1.rollout_class)"
            )
        try:
            locked = _coerce_rollout_class(
                tier1.rollout_class, "contract.tier1.rollout_class"
            )
        except (TypeError, ValueError) as exc:
            raise DeploymentContractError(str(exc)) from exc

        target = tier1.production_target
        if not isinstance(target, str) or not target.strip():
            raise DeploymentContractError(
                "deployment requires a non-empty "
                "contract.tier1.production_target"
            )

        data_class = _require_nonempty_text(
            self._adapter.data_class, "adapter data_class"
        )

        if requested_rollout is not None:
            requested = _coerce_rollout_class(requested_rollout, "requested_rollout")
            if requested is not locked:
                raise RolloutMismatchError(locked, requested)
        rollout = locked

        # Production deploy: one policy-classified operation on the exact
        # production target (spec 20.2; global contract: via the gate).
        self._gate.call(
            Operation(
                operation=DEPLOY_OPERATION,
                resource=target,
                data_class=data_class,
            ),
            {"target": target, "rollout_class": rollout.value},
        )

        if not self._adapter.health(target):
            # Health failed: rollback the SAME target through the gate
            # (fail closed -- a DENIED rollback propagates rather than
            # reporting a recovery that never happened).
            self._gate.call(
                Operation(
                    operation=ROLLBACK_OPERATION,
                    resource=target,
                    data_class=data_class,
                ),
                {"target": target},
            )
            return DeploymentOutcome.ROLLED_BACK
        return DeploymentOutcome.DEPLOYED
