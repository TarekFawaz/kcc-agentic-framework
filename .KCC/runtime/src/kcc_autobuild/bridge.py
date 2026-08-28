"""Execution Report bridge models for the KCC <-> Superpowers handoff.

Plan 03, Task 2/3 (Superpowers Execution Bridge): the worker's terminal
:class:`ExecutionReport` is an *evidence claim*, never proof.  KCC alone
accepts or advances a run, and :mod:`kcc_autobuild.evidence` re-checks
the chain-of-custody evidence (lease, commits, CI, usage) before the
claim is believed (plan Global Constraint: "Execution Report claims are
not trusted until KCC verifies chain-of-custody evidence").

Each fresh implementation agent instead receives a *bounded* task
handoff pack (:class:`ExecutionBridge` / :class:`TaskHandoff`, Task 3):
the scoped requirement/trace context, the acceptance criteria and Test
IDs, locked decisions with explicit ``LOCKED_DO_NOT_REDECIDE`` markers,
one KCC lease, the attempted budget and provider constraints (secret
references only) plus the canonical policy bundle hash -- Design Spec
v1.2 section 16.2 and section 28.3 (the Build Contract + Trace Matrix +
task handoff pack are the sole formal control-plane / execution-plane
interface).

The anchor invariant is enforced, not merely documented: the source
contract must be **locked** and an explicit ``policy_bundle_hash`` must
equal its canonical ``contract_hash``, so a self-inconsistent pack
anchored to the wrong policy bundle is rejected (fail-closed).  Scoping
is never silently disabled either: a missing trace graph (argument or
contract Trace Matrix) refuses the build instead of packing unscoped
context, the attempt budget is mandatory, authority-global accounts and
credential refs travel only on auto-provision-authorized provider
constraints, and a failed build never consumes a lease generation.

Plan 03, Task 2 (Superpowers Execution Bridge) context: Design Spec
v1.2 sections 16.2, 21, 22; plan Global Constraints.

Every execution attempt owns exactly one Execution Report bound to the
attempt lease (Global Constraint: "one KCC lease, one budget envelope,
one isolated workspace, and one Execution Report"), so the lease/run
identity and positive attempt number are required.  Status is
lowercase (``passed`` / ``failed`` / ``blocked``); a passed report must
declare acceptance evidence -- AC IDs, Test IDs and evidence refs --
and must not carry a failure classification, while failed/blocked
reports must carry one.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_execution_report.py`
and :file:`.KCC/runtime/tests/test_bridge.py`.
"""

from __future__ import annotations

import re
from collections import defaultdict, deque
from enum import Enum
from typing import Literal, Mapping

from pydantic import Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.contract import CONTRACT_HASH_PATTERN, BuildContract
from kcc_autobuild.models import (
    DependencyStatus,
    FailureClass,
    RUN_ID_PATTERN,
    StrictModel,
)
from kcc_autobuild.readiness import SECRET_REF_PATTERN
from kcc_autobuild.trace import TraceGraph, TraceNode

LOCKED_DO_NOT_REDECIDE = "LOCKED_DO_NOT_REDECIDE"
"""Explicit marker carried by every locked decision in a handoff pack
(Design Spec v1.2 section 16.2: explicit ``LOCKED -- DO NOT REDECIDE``
markers).  A :class:`LockedDecision` cannot carry any other marker.
"""

PLAINTEXT_SECRET_PATTERN = re.compile(r"sk-[A-Za-z0-9_-]{12,}")
"""Heuristic for a common plaintext API-key shape.

Handoff packs must never carry plaintext secrets (spec section 24 and
the plan Global Constraint chain-of-custody rule): credential data
travels as ``vault://`` / ``env://`` / ``keychain://`` references only.
The model rejects any pack that contains a matching raw secret; the
heuristic is deliberately narrow and is a defense-in-depth backstop on
top of the exclusive secret-reference rule for credential fields.
"""


class HandoffError(ValueError):
    """Raised when a task handoff cannot be built (fail-closed)."""


class HandoffOverflowError(HandoffError):
    """Raised when the serialized handoff pack exceeds the byte budget.

    Bounded packs are mandatory (spec 16.2): an oversized pack is
    rejected instead of being dispatched, so the control plane can
    rescope rather than silently truncate locked context.
    """


def _require_nonempty(value: str, name: str) -> str:
    if not value.strip():
        raise ValueError(f"{name} must not be empty")
    return value


def _require_nonempty_unique(values: list[str], name: str) -> list[str]:
    if not values:
        raise ValueError(f"{name} must not be empty")
    for value in values:
        _require_nonempty(value, name)
    if len(values) != len(set(values)):
        raise ValueError(f"{name} must not contain duplicates")
    return values


class ExecutionStatus(str, Enum):
    """Terminal status of one execution attempt (lowercase keys).

    A ``passed`` report is the only status whose evidence must prove
    the acceptance criteria; ``failed`` and ``blocked`` reports carry a
    :class:`FailureInfo` classification instead.
    """

    PASSED = "passed"
    FAILED = "failed"
    BLOCKED = "blocked"


class AcceptanceEvidence(StrictModel):
    """Evidence statement for one acceptance criterion.

    Each statement names the acceptance criterion (``acceptance_id``,
    e.g. ``AC-014-1``), the Test IDs that validate it (Design Spec
    section 10.2/12.4: every acceptance criterion maps to one or more
    Test IDs) and the evidence refs (paths/URLs of the test artifacts).
    """

    acceptance_id: str
    test_ids: list[str]
    evidence_refs: list[str]

    @field_validator("acceptance_id")
    @classmethod
    def _acceptance_id_nonempty(cls, value: str) -> str:
        return _require_nonempty(value, "acceptance_id")

    @field_validator("test_ids")
    @classmethod
    def _test_ids_nonempty(cls, value: list[str]) -> list[str]:
        return _require_nonempty_unique(value, "test_ids")

    @field_validator("evidence_refs")
    @classmethod
    def _evidence_refs_nonempty(cls, value: list[str]) -> list[str]:
        return _require_nonempty_unique(value, "evidence_refs")


class FailureInfo(StrictModel):
    """A classified failure of one execution attempt.

    ``cls`` is the failure-class alias and must be one of the canonical
    taxonomy AUTH|RATE|OUTAGE|BUG|DATA|ENV|CONTRACT|UNKNOWN
    (:class:`kcc_autobuild.models.FailureClass` -- the canonical enum,
    never renamed).
    """

    cls: FailureClass
    message: str

    @field_validator("message")
    @classmethod
    def _message_nonempty(cls, value: str) -> str:
        return _require_nonempty(value, "message")


class UsageInfo(StrictModel):
    """Claimed provider usage for the attempt (spend/token actuals).

    Values are nonnegative; KCC reconciles the claim against provider
    records before the report can be accepted (:class:`ProviderUsageVerifier`).
    """

    tokens: int = 0
    cost_usd: float = 0.0
    provider_calls: int = 0

    @field_validator("tokens", "provider_calls")
    @classmethod
    def _nonnegative_int(cls, value: int, info: ValidationInfo) -> int:
        if value < 0:
            raise ValueError(f"{info.field_name} must not be negative")
        return value

    @field_validator("cost_usd")
    @classmethod
    def _nonnegative_float(cls, value: float) -> float:
        if value < 0:
            raise ValueError("cost_usd must not be negative")
        return value


class OutputInfo(StrictModel):
    """One declared task output (artifact, commit or CI run).

    ``kind`` names the output type (``file``, ``commit``, ``ci-run``,
    ``test-report``, ...).  ``ref`` is the artifact path/URL or, for
    ``commit``/``ci-run`` kinds, the commit id / CI run ref.  ``commit``
    optionally names the commit that produced the output and is verified
    by :class:`kcc_autobuild.evidence.CommitVerifier`.
    """

    kind: str
    ref: str
    commit: str | None = None

    @field_validator("kind", "ref")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("commit")
    @classmethod
    def _commit_nonempty_when_present(cls, value: str | None) -> str | None:
        if value is not None:
            _require_nonempty(value, "commit")
        return value


class ExecutionReport(StrictModel):
    """Terminal Execution Report of one execution attempt (a claim).

    Chain of custody: the report is bound to the attempt lease
    (``lease_id`` + ``run_id`` + positive ``attempt``) and to its
    isolated workspace.  A ``passed`` report must declare acceptance
    evidence -- AC IDs, Test IDs and evidence refs -- and must not
    carry a failure classification; ``failed``/``blocked`` reports must
    carry one.

    Note: this is the claim only.  :class:`kcc_autobuild.evidence.EvidenceVerifier`
    is the only authority that turns a claim into an accepted outcome.
    """

    run_id: str = Field(pattern=RUN_ID_PATTERN)
    task_id: str
    attempt: int = Field(ge=1)
    status: ExecutionStatus
    lease_id: str
    workspace_id: str
    acceptance_evidence: list[AcceptanceEvidence] = Field(default_factory=list)
    failure: FailureInfo | None = None
    usage: UsageInfo
    outputs: list[OutputInfo] = Field(default_factory=list)
    deviations: list[str] = Field(default_factory=list)
    trace_updates: list[str] = Field(default_factory=list)

    @field_validator("task_id", "lease_id", "workspace_id")
    @classmethod
    def _identity_nonempty(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("deviations", "trace_updates")
    @classmethod
    def _entries_nonempty(cls, value: list[str], info: ValidationInfo) -> list[str]:
        for entry in value:
            _require_nonempty(entry, info.field_name)
        return value

    @model_validator(mode="after")
    def _acceptance_ids_unique(self) -> ExecutionReport:
        ac_ids = [evidence.acceptance_id for evidence in self.acceptance_evidence]
        if len(ac_ids) != len(set(ac_ids)):
            raise ValueError("acceptance of the report must reference unique AC ids")
        return self

    @model_validator(mode="after")
    def _status_evidence_consistency(self) -> ExecutionReport:
        if self.status is ExecutionStatus.PASSED:
            if not self.acceptance_evidence:
                raise ValueError(
                    "passed reports must declare acceptance evidence "
                    "(AC IDs, Test IDs and evidence refs)"
                )
            if self.failure is not None:
                raise ValueError(
                    "passed reports must not carry a failure classification"
                )
        elif self.failure is None:
            raise ValueError(
                f"{self.status.value} reports must carry a failure classification"
            )
        return self


# ---------------------------------------------------------------------------
# Task 4 -- harness metadata normalization (Plan 08, Task 4).
#
# A harness worker's raw report document may carry harness-metadata
# fields next to the canonical ExecutionReport fields (invocation facts,
# model names, durations, captured output).  The adapter normalizes the
# document by removing harness metadata ONLY: every other field is
# preserved and still validated against the strict ExecutionReport
# schema, so a non-metadata extra field fails closed instead of being
# dropped.
# ---------------------------------------------------------------------------

HARNESS_METADATA_FIELDS: frozenset[str] = frozenset(
    {
        "harness",
        "harness_id",
        "harness_metadata",
        "worker",
        "worker_id",
        "session_id",
        "profile",
        "dsh",
        "model",
        "provider",
        "invocation",
        "invoked_at",
        "started_at",
        "finished_at",
        "duration_ms",
        "duration_seconds",
        "exit_code",
        "stdout",
        "stderr",
        "final_message",
        "raw_output",
        "tool_calls",
        "tools",
        "log",
        "logs",
        "banner",
        "kcc_dsh_status",
    }
)
"""Harness-metadata field names a raw worker report may carry.

These describe the harness invocation/environment only -- never task
evidence -- so they are the only fields
:func:`normalize_harness_metadata` removes.  Lease identity, acceptance
criteria, Test IDs, usage, deviations, policy trace and evidence fields
are never treated as harness metadata.
"""


def normalize_harness_metadata(document: Mapping[str, object]) -> dict[str, object]:
    """Remove harness-metadata fields from a raw worker report document.

    The normalized document keeps every non-metadata field untouched --
    including fields that are not part of the ExecutionReport schema,
    which then still fail the strict model validation (fail closed).
    Non-string keys and non-mapping documents are rejected rather than
    guessed.
    """
    if not isinstance(document, Mapping):
        raise TypeError("ExecutionReport document must be a mapping")
    normalized: dict[str, object] = {}
    for key, value in document.items():
        if not isinstance(key, str):
            raise TypeError("ExecutionReport document keys must be strings")
        if key in HARNESS_METADATA_FIELDS:
            continue
        normalized[key] = value
    return normalized


# ---------------------------------------------------------------------------
# Task 3 -- bounded task handoff packs (Design Spec v1.2 section 16.2)
# ---------------------------------------------------------------------------


class LockedDecision(StrictModel):
    """One locked contract/decision excerpt carried in a handoff pack.

    Explicitly marked ``LOCKED_DO_NOT_REDECIDE`` (spec 16.2): a Tier-1
    decision or ADR excerpt the worker must treat as settled.  The
    marker is a literal type, so a decision without the exact marker
    cannot be constructed, and ``requirement_ids`` binds the decision to
    the requirements it applies to (empty means global, i.e. it applies
    to every task of the run).
    """

    id: str
    summary: str
    requirement_ids: list[str] = Field(default_factory=list)
    marker: Literal["LOCKED_DO_NOT_REDECIDE"] = LOCKED_DO_NOT_REDECIDE

    @field_validator("id", "summary")
    @classmethod
    def _text_nonempty(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("requirement_ids")
    @classmethod
    def _requirement_ids_nonempty_entries(cls, value: list[str]) -> list[str]:
        for entry in value:
            _require_nonempty(entry, "requirement_ids")
        return value


class TaskLease(StrictModel):
    """The single KCC lease bound to this execution attempt.

    One lease per attempt (Global Constraint "one KCC lease ... one
    Execution Report"): the lease is bound to the run and the task it
    was issued for, and its ``generation`` is strictly positive and
    increments with every handoff the bridge issues.
    """

    lease_id: str
    run_id: str = Field(pattern=RUN_ID_PATTERN)
    task_id: str
    generation: int = Field(ge=1)

    @field_validator("lease_id", "task_id")
    @classmethod
    def _identity_nonempty(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)


class AttemptBudget(StrictModel):
    """KCC-owned retry/time/token/cost budget for this attempt (spec 17).

    Maximum attempts plus time, token and cost budgets and the
    escalation tier of the self-heal ladder; the worker may never
    exceed or re-negotiate these.
    """

    max_attempts: int = Field(ge=1)
    time_budget_minutes: int = Field(ge=1)
    token_budget: int = Field(ge=0)
    cost_budget_minor: int = Field(ge=0)
    escalation_tier: int = Field(ge=1)


class ProviderConstraint(StrictModel):
    """One scoped provider constraint for the task (spec 16.2).

    Derived from the locked contract's provider whitelist, authority
    envelope and money policy: ``spend_cap`` (minor units) and
    ``auto_provision`` are bounded per provider, ``approved_accounts``
    only travel when this provider is auto-provision authorized, and
    ``credential_refs`` are secret *references* only (``vault://`` /
    ``env://`` / ``keychain://``) -- raw secrets are rejected (spec
    section 24, R4: the canonical ``AUTO_PROVISION_AUTHORIZED`` status
    is referenced here and never renamed).
    """

    provider: str
    paid: bool = False
    approved_accounts: list[str] = Field(default_factory=list)
    spend_cap: int | None = None
    credential_refs: list[str] = Field(default_factory=list)
    auto_provision: DependencyStatus = DependencyStatus.USER_MUST_PROVIDE

    @field_validator("provider")
    @classmethod
    def _provider_nonempty(cls, value: str) -> str:
        return _require_nonempty(value, "provider")

    @field_validator("approved_accounts")
    @classmethod
    def _accounts_nonempty_entries(cls, value: list[str]) -> list[str]:
        for entry in value:
            _require_nonempty(entry, "approved_accounts")
        return value

    @field_validator("spend_cap")
    @classmethod
    def _spend_cap_positive_when_set(cls, value: int | None) -> int | None:
        if value is not None and value < 1:
            raise ValueError("spend_cap must be strictly positive when set")
        return value

    @field_validator("credential_refs")
    @classmethod
    def _credential_refs_are_secret_references(
        cls, value: list[str]
    ) -> list[str]:
        for entry in value:
            _require_nonempty(entry, "credential_refs")
            if not re.fullmatch(SECRET_REF_PATTERN, entry):
                raise ValueError(
                    f"credential_ref '{entry}' must be a secret reference "
                    "(vault://, env:// or keychain://)"
                )
        return value


class TaskHandoff(StrictModel):
    """The bounded task handoff pack of Design Spec v1.2 section 16.2.

    Fields (Plan 03, Task 3): ``run_id``, ``task_id``,
    ``requirement_ids``, ``trace_nodes``, ``acceptance_ids``,
    ``test_ids``, ``locked_decisions``, ``lease``, ``attempt_budget``,
    ``provider_constraints`` and ``policy_bundle_hash``.

    The pack is scoped: ``trace_nodes`` are the forward-reachable trace
    context of the task's requirements, acceptance/Test IDs must be
    non-empty (spec 21: every acceptance criterion maps to required
    Test IDs) and the lease must be bound to the very run/task the pack
    belongs to.  Raw secrets are rejected anywhere in the pack; the
    canonical policy bundle hash anchors the pack to the locked policy
    bundle (evaluator signature/hash).

    :meth:`pack` returns the deterministic serialized pack; the bridge
    refuses to return a pack that exceeds its byte limit instead of
    silently truncating locked context.
    """

    run_id: str = Field(pattern=RUN_ID_PATTERN)
    task_id: str
    requirement_ids: list[str]
    trace_nodes: list[TraceNode] = Field(default_factory=list)
    acceptance_ids: list[str]
    test_ids: list[str]
    locked_decisions: list[LockedDecision] = Field(default_factory=list)
    lease: TaskLease
    attempt_budget: AttemptBudget
    provider_constraints: list[ProviderConstraint] = Field(default_factory=list)
    policy_bundle_hash: str = Field(pattern=CONTRACT_HASH_PATTERN)

    @field_validator("task_id")
    @classmethod
    def _task_id_nonempty(cls, value: str) -> str:
        return _require_nonempty(value, "task_id")

    @field_validator("requirement_ids", "acceptance_ids", "test_ids")
    @classmethod
    def _id_lists_nonempty_unique(
        cls, value: list[str], info: ValidationInfo
    ) -> list[str]:
        return _require_nonempty_unique(value, info.field_name)

    @field_validator("trace_nodes")
    @classmethod
    def _trace_nodes_unique(cls, value: list[TraceNode]) -> list[TraceNode]:
        node_ids = [node.id for node in value]
        if len(node_ids) != len(set(node_ids)):
            raise ValueError("trace_nodes must not contain duplicate node ids")
        return value

    @field_validator("locked_decisions")
    @classmethod
    def _decisions_unique(cls, value: list[LockedDecision]) -> list[LockedDecision]:
        decision_ids = [decision.id for decision in value]
        if len(decision_ids) != len(set(decision_ids)):
            raise ValueError("locked_decisions must not contain duplicate ids")
        return value

    @field_validator("provider_constraints")
    @classmethod
    def _providers_unique(
        cls, value: list[ProviderConstraint]
    ) -> list[ProviderConstraint]:
        providers = [constraint.provider for constraint in value]
        if len(providers) != len(set(providers)):
            raise ValueError("provider_constraints must not contain duplicates")
        return value

    @model_validator(mode="after")
    def _lease_bound_to_handoff(self) -> TaskHandoff:
        if self.lease.run_id != self.run_id:
            raise ValueError("lease must be bound to the handoff run_id")
        if self.lease.task_id != self.task_id:
            raise ValueError("lease must be bound to the handoff task_id")
        return self

    @model_validator(mode="after")
    def _no_plaintext_secrets(self) -> TaskHandoff:
        if PLAINTEXT_SECRET_PATTERN.search(self.model_dump_json()):
            raise ValueError(
                "handoff must not contain plaintext secrets "
                "(credential data travels as secret references only)"
            )
        return self

    def pack(self) -> bytes:
        """Deterministic serialized form of the bounded pack."""
        return self.model_dump_json().encode("utf-8")


class ExecutionBridge:
    """Builds bounded, scoped :class:`TaskHandoff` packs (spec 16.2).

    ``max_handoff_bytes`` bounds the serialized pack (default 65536).
    The bridge carries the scoping rules: only the task's requirements
    and their forward-reachable trace context are packed, acceptance
    and Test IDs must exist and be reachable from the task's
    requirements (missing or unrelated IDs are rejected), provider
    constraints are derived from the locked contract and scoped to the
    task's providers, locked decisions are scoped to the task's
    requirements and every pack is anchored to the canonical policy
    bundle hash.  Each issued pack gets a fresh lease with a strictly
    positive, incrementing generation (one lease per attempt).

    The anchor invariant is enforced, not documented: **the source
    contract must be locked** and an explicit ``policy_bundle_hash``
    must equal the locked contract's canonical ``contract_hash`` -- a
    mismatch is rejected (fail-closed) so a self-inconsistent pack
    anchored to the wrong policy bundle can never be produced.

    Scoping is never silently disabled: without a ``trace`` graph the
    bridge falls back to the contract's Trace Matrix, and with no trace
    source at all it refuses to build (acceptance/Test-ID reachability
    cannot be proven).  The attempt budget is required (KCC owns it)
    and every input is validated before the lease generation is
    committed: a failed build never consumes a generation, so one
    lease generation corresponds to exactly one *issued* pack.
    """

    def __init__(self, *, max_handoff_bytes: int = 65536) -> None:
        if max_handoff_bytes < 1:
            raise ValueError("max_handoff_bytes must be positive")
        self.max_handoff_bytes = max_handoff_bytes
        self._lease_generation = 0

    def build_handoff(
        self,
        *,
        run_id: str,
        task_id: str,
        requirement_ids: list[str],
        acceptance_ids: list[str],
        test_ids: list[str],
        providers: list[str] | None = None,
        trace: TraceGraph | None = None,
        contract: BuildContract | None = None,
        locked_decisions: list[LockedDecision] | None = None,
        attempt_budget: AttemptBudget | None = None,
        policy_bundle_hash: str | None = None,
    ) -> TaskHandoff:
        """Build the bounded pack or raise (fail-closed, never truncate)."""
        if not requirement_ids:
            raise HandoffError(
                "task scope must declare at least one requirement id"
            )
        if not acceptance_ids:
            raise HandoffError(
                "task scope must declare at least one acceptance id"
            )
        if not test_ids:
            raise HandoffError("task scope must declare at least one test id")
        if attempt_budget is None:
            raise HandoffError(
                "attempt budget is required (KCC owns the attempt budget)"
            )
        bundle_hash = self._anchor_hash(contract, policy_bundle_hash)
        trace_graph = trace if trace is not None else (
            contract.trace if contract is not None else None
        )
        if trace_graph is None:
            raise HandoffError(
                "trace graph is required to scope the handoff (pass the "
                "task's trace context or the contract's Trace Matrix)"
            )
        trace_nodes = self._scoped_trace_context(
            requirement_ids, acceptance_ids, test_ids, trace_graph
        )
        constraints = self._provider_constraints(providers, contract)
        decisions = self._scoped_decisions(locked_decisions, requirement_ids)

        handoff = TaskHandoff(
            run_id=run_id,
            task_id=task_id,
            requirement_ids=list(requirement_ids),
            trace_nodes=trace_nodes,
            acceptance_ids=list(acceptance_ids),
            test_ids=list(test_ids),
            locked_decisions=decisions,
            lease=TaskLease(
                lease_id=f"LEASE-{run_id}-{task_id}-{self._lease_generation + 1}",
                run_id=run_id,
                task_id=task_id,
                generation=self._lease_generation + 1,
            ),
            attempt_budget=attempt_budget,
            provider_constraints=constraints,
            policy_bundle_hash=bundle_hash,
        )
        payload = handoff.pack()
        if len(payload) > self.max_handoff_bytes:
            raise HandoffOverflowError(
                f"handoff pack is {len(payload)} bytes, exceeding "
                f"max_handoff_bytes={self.max_handoff_bytes}"
            )
        # A generation is committed only for an issued pack: a failed
        # build (validation or overflow) must never consume one.
        self._lease_generation += 1
        return handoff

    @staticmethod
    def _anchor_hash(
        contract: BuildContract | None,
        policy_bundle_hash: str | None,
    ) -> str:
        """Resolve and cross-verify the pack's policy bundle anchor.

        The anchor invariant: ``policy_bundle_hash`` is the canonical
        hash of the exact locked policy bundle the pack was built from.
        When the source contract is supplied it must be **locked**
        (canonical ``contract_hash`` present); an explicit
        ``policy_bundle_hash`` must equal that canonical hash.  A
        mismatch (or an unlocked contract) is rejected, so a
        self-inconsistent pack anchored to the wrong policy bundle can
        never be produced.
        """
        if contract is not None:
            if contract.contract_hash is None:
                raise HandoffError(
                    "contract must be locked before a handoff can be "
                    "anchored to it (an unlocked contract has no canonical "
                    "policy bundle hash to cross-verify against)"
                )
            if (
                policy_bundle_hash is not None
                and policy_bundle_hash != contract.contract_hash
            ):
                raise HandoffError(
                    f"policy_bundle_hash does not match the locked "
                    f"contract's canonical contract_hash "
                    f"({policy_bundle_hash!r} != {contract.contract_hash!r})"
                )
            return contract.contract_hash
        if policy_bundle_hash is None:
            raise HandoffError(
                "policy bundle hash is required (pass the locked "
                "contract's canonical hash)"
            )
        return policy_bundle_hash

    def _scoped_trace_context(
        self,
        requirement_ids: list[str],
        acceptance_ids: list[str],
        test_ids: list[str],
        trace: TraceGraph | None,
    ) -> list[TraceNode]:
        """Forward-reachable trace context of the task requirements.

        Unrelated requirements (and their whole cluster) are excluded;
        acceptance and Test IDs must be present in the reachable set
        (as acceptance/test nodes respectively) or the build is
        rejected -- only scoped context can travel.  A missing trace
        graph never silently disables scoping: reachability cannot be
        proven without one, so the build is refused (fail-closed).
        """
        if trace is None:
            raise HandoffError(
                "trace graph is required to scope the handoff (pass the "
                "task's trace context or the contract's Trace Matrix)"
            )
        kind_by_id = {node.id: node.kind for node in trace.nodes}
        for requirement_id in requirement_ids:
            if requirement_id not in kind_by_id:
                raise HandoffError(
                    f"requirement '{requirement_id}' is not in the trace graph"
                )
            if kind_by_id[requirement_id] != "requirement":
                raise HandoffError(
                    f"'{requirement_id}' is not a requirement node in the "
                    "trace graph"
                )
        reachable = self._reachable(trace, requirement_ids)
        for acceptance_id in acceptance_ids:
            if acceptance_id not in reachable:
                raise HandoffError(
                    f"acceptance '{acceptance_id}' is not reachable from the "
                    "task requirements"
                )
            if kind_by_id[acceptance_id] != "acceptance":
                raise HandoffError(
                    f"'{acceptance_id}' is not an acceptance node in the "
                    "task's trace context"
                )
        for test_id in test_ids:
            if test_id not in reachable:
                raise HandoffError(
                    f"test '{test_id}' is not reachable from the task "
                    "requirements"
                )
            if kind_by_id[test_id] != "test":
                raise HandoffError(
                    f"'{test_id}' is not a test node in the task's trace "
                    "context"
                )
        return [
            TraceNode(id=node_id, kind=kind_by_id[node_id])
            for node_id in sorted(reachable)
        ]

    @staticmethod
    def _reachable(trace: TraceGraph, requirement_ids: list[str]) -> set[str]:
        adjacency: dict[str, list[str]] = defaultdict(list)
        for edge in trace.edges:
            adjacency[edge.source].append(edge.target)
        seen: set[str] = set()
        queue: deque[str] = deque(requirement_ids)
        while queue:
            node_id = queue.popleft()
            if node_id in seen:
                continue
            seen.add(node_id)
            queue.extend(adjacency.get(node_id, []))
        return seen

    def _provider_constraints(
        self,
        providers: list[str] | None,
        contract: BuildContract | None,
    ) -> list[ProviderConstraint]:
        """Scoped provider constraints derived from the locked contract."""
        if contract is None:
            if providers:
                raise HandoffError(
                    "provider constraints require a contract (pass the "
                    "locked contract)"
                )
            return []
        whitelist = {
            entry.provider: entry for entry in contract.tier1.provider_whitelist
        }
        selected = list(whitelist) if providers is None else list(providers)
        for provider in selected:
            if provider not in whitelist:
                raise HandoffError(
                    f"provider '{provider}' is not on the contract provider "
                    "whitelist"
                )
        authority = contract.tier1.authority
        money = contract.tier1.money
        auto_provision_authorized = (
            authority.auto_provision_status
            is DependencyStatus.AUTO_PROVISION_AUTHORIZED
        )
        constraints: list[ProviderConstraint] = []
        for provider in selected:
            authorized = (
                auto_provision_authorized
                and provider in authority.auto_provision_providers
            )
            # Authority-global accounts and credential refs belong to
            # the auto-provision-authorized provider set only; they are
            # NEVER copied onto an out-of-scope provider's constraint
            # (fail-closed: a USER_MUST_PROVIDE provider carries no
            # authority-global account/credential material at all).
            constraints.append(
                ProviderConstraint(
                    provider=provider,
                    paid=whitelist[provider].paid,
                    approved_accounts=(
                        list(authority.approved_accounts) if authorized else []
                    ),
                    spend_cap=money.per_provider_caps.get(provider),
                    credential_refs=(
                        list(authority.credential_refs) if authorized else []
                    ),
                    auto_provision=(
                        DependencyStatus.AUTO_PROVISION_AUTHORIZED
                        if authorized
                        else DependencyStatus.USER_MUST_PROVIDE
                    ),
                )
            )
        return constraints

    @staticmethod
    def _scoped_decisions(
        locked_decisions: list[LockedDecision] | None,
        requirement_ids: list[str],
    ) -> list[LockedDecision]:
        """Only decisions binding the task's requirements (or global)."""
        if not locked_decisions:
            return []
        scope = set(requirement_ids)
        return sorted(
            (
                decision
                for decision in locked_decisions
                if not decision.requirement_ids
                or scope.intersection(decision.requirement_ids)
            ),
            key=lambda decision: decision.id,
        )
