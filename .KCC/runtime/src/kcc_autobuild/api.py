"""Autobuild discovery control-plane API: redacted projections + commands.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_api.py`
(see the KCC x Superpowers Hybrid Framework Plan 06, Task 1; Design
Spec v1.2; plan Global Constraints on stale-state discipline and
projection safety).

The canvas (discovery UI) talks to this WSGI app only:

* GET ``/run``, ``/trace``, ``/readiness``, ``/contract`` — redacted
  projections of the run record, the trace graph (server-owned, with
  coverage so orphan requirements surface as blockers), the evidence
  readiness evaluation and the two-tier Build Contract;
* POST ``/h1`` (scope confirmation), ``/h2`` (prototype walkthrough),
  ``/lock`` (LOCK & BUILD), ``/pause``, ``/resume`` — every command
  carries ``expected_state`` and ``/lock`` additionally carries
  ``tier1_hash``.

Stale-state discipline: a command whose ``expected_state`` does not
match the stored run state responds HTTP 409 ``STALE_STATE``; a LOCK
whose ``tier1_hash`` does not match the canonical Tier-1 hash of the
current contract responds HTTP 409 ``STALE_CONTRACT``.  The typed
canvas client maps both to ``StaleProjectionError`` and never
auto-retries LOCK.  Invalid transitions, un-lockable contracts,
malformed requests and unknown runs fail closed (400/404/405), never
auto-healed.

Projection safety: the control-plane API exposes secret REFERENCES
(``vault://``, ``env://``, ``keychain://``) only — raw secret values
never appear in any response.  :func:`redact_secrets` is the single
redaction engine applied to every projection and command response, and
the production adapter (:class:`StoreCanvasService`, built from the
RunStore / trace / readiness pack / contract) feeds every projection
through it.

The app is a dependency-free WSGI application so the runtime stays on
its minimal dependency set; :func:`serve` runs it without any web
framework.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Protocol, cast, runtime_checkable

from pydantic import Field, ValidationError

from kcc_autobuild.contract import (
    CONTRACT_HASH_PATTERN,
    BuildContract,
    ContractLockError,
    ResumeProtocol,
    Tier1Invariants,
    Tier2Details,
    lock_contract,
    tier1_canonical_hash,
)
from kcc_autobuild.models import (
    RUN_ID_PATTERN,
    LifecycleState,
    ReadinessStatus,
    RunRecord,
    StrictModel,
)
from kcc_autobuild.readiness import (
    EvidenceRecord,
    FallbackEntry,
    ReadinessItem,
    ReadinessPack,
    SECRET_REF_PATTERN,
    evaluate_readiness,
)
from kcc_autobuild.state_machine import InvalidTransition, assert_transition
from kcc_autobuild.store import ConcurrentStateChange, RunStore
from kcc_autobuild.trace import (
    TraceCoverageResult,
    TraceEdge,
    TraceGraph,
    TraceNode,
    validate_trace_coverage,
)

SECRET_REDACTED = "[REDACTED]"
"""Marker replacing any redacted raw secret in a projection."""

SECRET_KEY_PATTERN = re.compile(
    r"(secret|token|password|passwd|credential|"
    r"api[_-]?key|access[_-]?key|private[_-]?key|signing[_-]?key|"
    r"authorization|bearer|client[_-]?secret)",
    re.IGNORECASE,
)
"""Key names that carry secret material.

Conservative on purpose: bare ``auth``/``key``/``security`` are NOT
matched (``auth_model``, ``provider_key``, ``security_constraints`` are
legitimate non-secret contract fields).
"""

RAW_SECRET_PATTERN = re.compile(
    r"(?:"
    r"\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}\b"  # OpenAI/Anthropic-style live key
    r"|\bAKIA[0-9A-Z]{16}\b"  # AWS access key id
    r"|\bgh[pousr]_[A-Za-z0-9]{20,}\b"  # GitHub token
    r"|\bxox[baprs]-[A-Za-z0-9-]{10,}\b"  # Slack token
    r"|\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b"  # JWT
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"  # PEM private key
    r")"
)
"""Value patterns of raw secret material (defense in depth).

Matched anywhere a string value appears, even under a generic key, so a
raw secret smuggled into a trace label, reason or test-result string is
still redacted.  Contract hashes and refs are deliberately NOT matched.
"""


def _is_secret_ref(value: str) -> bool:
    """True when a string is a secret REFERENCE (never raw material)."""
    return re.fullmatch(SECRET_REF_PATTERN, value) is not None


def _only_secret_refs(value: Any) -> bool:
    """True when a subtree consists exclusively of secret references."""
    if isinstance(value, str):
        return _is_secret_ref(value)
    if isinstance(value, dict):
        return all(_only_secret_refs(sub) for sub in value.values())
    if isinstance(value, list):
        return all(_only_secret_refs(item) for item in value)
    return False


def redact_secrets(value: Any) -> Any:
    """Recursively redact raw secret values from JSON-safe data.

    Rules (fail closed):

    * secret references (``vault://``, ``env://``, ``keychain://``)
      are preserved — the API exposes refs only;
    * a string or container under a secret-ish key is preserved only
      when the whole subtree is secret references; otherwise it becomes
      :data:`SECRET_REDACTED` (non-string scalars such as booleans,
      numbers or null pass through — they are metadata, not secret
      material, e.g. the authority ``secret_reference_usage`` flag);
    * any string value containing a raw-secret shape
      (:data:`RAW_SECRET_PATTERN`) becomes :data:`SECRET_REDACTED`
      regardless of its key;
    * every other structure is traversed in place.
    """
    if isinstance(value, str):
        if _is_secret_ref(value) or RAW_SECRET_PATTERN.search(value) is None:
            return value
        return SECRET_REDACTED
    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, sub in value.items():
            if isinstance(key, str) and SECRET_KEY_PATTERN.search(key):
                if isinstance(sub, (str, dict, list)):
                    redacted[key] = (
                        sub if _only_secret_refs(sub) else SECRET_REDACTED
                    )
                else:
                    redacted[key] = sub
            else:
                redacted[key] = redact_secrets(sub)
        return redacted
    if isinstance(value, list):
        return [redact_secrets(item) for item in value]
    return value


# ---------------------------------------------------------------------------
# Command requests
# ---------------------------------------------------------------------------


class CommandRequest(StrictModel):
    """A canvas command: every command carries the expected run state."""

    expected_state: LifecycleState


class LockRequest(CommandRequest):
    """LOCK & BUILD: the client proves the projection it approved."""

    tier1_hash: str = Field(pattern=CONTRACT_HASH_PATTERN)


# ---------------------------------------------------------------------------
# Redacted projections
# ---------------------------------------------------------------------------


class RunProjection(StrictModel):
    """Public projection of one autobuild run."""

    run_id: str = Field(pattern=RUN_ID_PATTERN)
    title: str
    created_at: datetime
    state: LifecycleState
    contract_hash: str | None = None


class TraceProjection(StrictModel):
    """Server-owned trace graph plus coverage (orphans become blockers)."""

    run_id: str | None = None
    nodes: list[TraceNode] = Field(default_factory=list)
    edges: list[TraceEdge] = Field(default_factory=list)
    coverage: TraceCoverageResult = Field(default_factory=TraceCoverageResult)


class ReadinessItemProjection(StrictModel):
    """One readiness subject: evaluation outcome, evidence, fallback refs."""

    item_id: str
    status: ReadinessStatus
    reasons: list[str] = Field(default_factory=list)
    evidence: list[EvidenceRecord] = Field(default_factory=list)
    fallbacks: list[FallbackEntry] = Field(default_factory=list)
    evidence_current: bool


class ReadinessProjection(StrictModel):
    """Evidence-backed readiness of the run (the LOCK surface inputs)."""

    ready: bool
    coverage_ok: bool
    blockers: list[str] = Field(default_factory=list)
    open_red_team_findings: list[str] = Field(default_factory=list)
    evidence_stale: bool
    items: list[ReadinessItemProjection] = Field(default_factory=list)


class ContractProjection(StrictModel):
    """The two-tier Build Contract as the canvas may view it.

    ``present`` marks a missing contract (discovery has not produced
    one yet).  ``tier1_hash`` is the canonical Tier-1 hash — the value
    the canvas proves at LOCK — while ``contract_hash`` / ``tier2_hash``
    are the lock-time hashes, stored only when the contract is locked.
    """

    present: bool = False
    contract_version: str = "1.0"
    tier1_hash: str | None = None
    tier1: Tier1Invariants | None = None
    tier2: Tier2Details | None = None
    trace: TraceGraph | None = None
    readiness: ReadinessPack | None = None
    resume: ResumeProtocol | None = None
    locked_at: datetime | None = None
    contract_hash: str | None = None
    tier2_hash: str | None = None


class CommandResult(StrictModel):
    """Result of an accepted canvas command (redacted run projection)."""

    command: str
    accepted: bool = True
    run: RunProjection


# ---------------------------------------------------------------------------
# Service errors (mapped by create_app to HTTP responses)
# ---------------------------------------------------------------------------


class StaleStateError(ValueError):
    """The command's ``expected_state`` no longer matches the run."""


class StaleContractError(ValueError):
    """The LOCK ``tier1_hash`` no longer matches the current contract."""


class UnknownRunError(KeyError):
    """The run does not exist in the store (never create-on-read)."""


# ---------------------------------------------------------------------------
# CanvasService protocol
# ---------------------------------------------------------------------------


@runtime_checkable
class CanvasService(Protocol):
    """Typed facade the discovery canvas talks to.

    Implementations must raise :class:`StaleStateError` /
    :class:`StaleContractError` for the stale-state discipline and
    :class:`InvalidTransition` for commands the run cannot legally
    accept.  Every projection must be redacted (secret refs only).
    """

    def run_projection(self) -> RunProjection: ...

    def trace_projection(self) -> TraceProjection: ...

    def readiness_projection(self) -> ReadinessProjection: ...

    def contract_projection(self) -> ContractProjection: ...

    def confirm_h1(self, request: CommandRequest) -> CommandResult: ...

    def confirm_h2(self, request: CommandRequest) -> CommandResult: ...

    def lock(self, request: LockRequest) -> CommandResult: ...

    def pause(self, request: CommandRequest) -> CommandResult: ...

    def resume(self, request: CommandRequest) -> CommandResult: ...


# ---------------------------------------------------------------------------
# Production adapter: RunStore + trace + readiness + contract (redacting)
# ---------------------------------------------------------------------------


def _as_utc(value: datetime, name: str = "now") -> datetime:
    """Require a timezone-aware instant; normalize to UTC (fail closed)."""
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")
    return value.astimezone(timezone.utc)


def item_evidence_current(item: ReadinessItem, now: datetime) -> bool:
    """True when every required probe kind has evidence within the TTL.

    ``current`` is about freshness, not verdict: any record checked
    inside the item's freshness window (and not in the future) counts,
    while the readiness evaluation itself stays fail-closed on the
    freshest record's verdict.
    """
    for kind in item.required_kinds:
        records = [record for record in item.evidence if record.kind == kind]
        if not any(
            timedelta(0) <= now - record.checked_at <= item.evidence_ttl
            for record in records
        ):
            return False
    return True


class StoreCanvasService:
    """Production adapter over the RunStore plus the discovery artifacts.

    Built from exactly the control-plane sources the plan names
    (RunStore / trace graph / readiness pack / Build Contract); all
    four projections are produced here and passed through
    :func:`redact_secrets` by :func:`create_app`, so raw secrets cannot
    reach a response.

    The adapter trims the persistence of the controller: ``lock`` runs
    the real ``lock_contract`` gates before the durable
    ``CONTRACT_REVIEW -> LOCKED`` transition (the controller starts the
    build once the run is LOCKED), ``pause`` is BUILDING-only and
    ``resume`` moves ``PAUSED -> RESUMING -> BUILDING`` exactly like
    :class:`kcc_autobuild.controller.AutobuildController`.
    """

    def __init__(
        self,
        run_id: str,
        store: RunStore,
        *,
        trace: TraceGraph | None = None,
        readiness: ReadinessPack | None = None,
        contract: BuildContract | None = None,
        now: datetime | None = None,
    ) -> None:
        if re.fullmatch(RUN_ID_PATTERN, run_id) is None:
            raise ValueError(f"invalid run_id {run_id!r}; must match {RUN_ID_PATTERN}")
        self._run_id = run_id
        self._store = store
        self._contract = contract
        self._trace = (
            trace
            if trace is not None
            else (contract.trace if contract is not None else None)
        )
        self._readiness = (
            readiness
            if readiness is not None
            else (contract.readiness if contract is not None else None)
        )
        self._now = now

    def _now_utc(self) -> datetime:
        if self._now is None:
            return datetime.now(timezone.utc)
        return _as_utc(self._now)

    # -- source helpers --------------------------------------------------

    def _load_run(self) -> RunRecord:
        try:
            return self._store.load_run(self._run_id)
        except KeyError:
            raise UnknownRunError(
                f"run {self._run_id!r} was not found"
            ) from None

    def _require_state(self, expected: LifecycleState) -> RunRecord:
        """Return the run when its stored state equals ``expected``."""
        record = self._load_run()
        if record.state is not expected:
            raise StaleStateError(
                f"run {self._run_id!r} is {record.state.value}, "
                f"expected {expected.value}"
            )
        return record

    def _transition(
        self, current: LifecycleState, target: LifecycleState, reason: str
    ) -> None:
        try:
            self._store.transition(
                self._run_id, expected=current, target=target, reason=reason
            )
        except ConcurrentStateChange as exc:
            raise StaleStateError(str(exc)) from exc

    # -- projections ------------------------------------------------------

    def run_projection(self) -> RunProjection:
        record = self._load_run()
        contract_hash = record.contract_hash
        if contract_hash is None and self._contract is not None:
            contract_hash = self._contract.contract_hash
        return RunProjection(
            run_id=record.run_id,
            title=record.title,
            created_at=record.created_at,
            state=record.state,
            contract_hash=contract_hash,
        )

    def trace_projection(self) -> TraceProjection:
        graph = self._trace if self._trace is not None else TraceGraph()
        return TraceProjection(
            run_id=graph.run_id,
            nodes=graph.nodes,
            edges=graph.edges,
            coverage=validate_trace_coverage(graph),
        )

    def readiness_projection(self) -> ReadinessProjection:
        pack = self._readiness if self._readiness is not None else ReadinessPack()
        now = self._now_utc()
        evaluation = evaluate_readiness(pack, now=now)
        ordered = sorted(pack.items, key=lambda item: item.id)
        by_id = {item.id: item for item in ordered}
        items = [
            ReadinessItemProjection(
                item_id=outcome.item_id,
                status=outcome.status,
                reasons=outcome.reasons,
                evidence=by_id[outcome.item_id].evidence,
                fallbacks=by_id[outcome.item_id].fallbacks,
                evidence_current=item_evidence_current(
                    by_id[outcome.item_id], now
                ),
            )
            for outcome in evaluation.items
        ]
        return ReadinessProjection(
            ready=evaluation.ready,
            coverage_ok=evaluation.coverage_ok,
            blockers=evaluation.blockers,
            open_red_team_findings=evaluation.open_red_team_findings,
            evidence_stale=any(not item.evidence_current for item in items),
            items=items,
        )

    def contract_projection(self) -> ContractProjection:
        contract = self._contract
        if contract is None:
            return ContractProjection()
        return ContractProjection(
            present=True,
            contract_version=contract.contract_version,
            tier1_hash=tier1_canonical_hash(contract),
            tier1=contract.tier1,
            tier2=contract.tier2,
            trace=contract.trace,
            readiness=contract.readiness,
            resume=contract.resume,
            locked_at=contract.locked_at,
            contract_hash=contract.contract_hash,
            tier2_hash=contract.tier2_hash,
        )

    # -- commands ----------------------------------------------------------

    def confirm_h1(self, request: CommandRequest) -> CommandResult:
        """H1 scope confirmation: DISCOVERY -> PROTOTYPE_REVIEW."""
        record = self._require_state(request.expected_state)
        assert_transition(record.state, LifecycleState.PROTOTYPE_REVIEW)
        self._transition(
            record.state, LifecycleState.PROTOTYPE_REVIEW, "h1-scope-confirmed"
        )
        return CommandResult(command="h1", run=self.run_projection())

    def confirm_h2(self, request: CommandRequest) -> CommandResult:
        """H2 prototype walkthrough: PROTOTYPE_REVIEW -> ARCHITECTURE."""
        record = self._require_state(request.expected_state)
        assert_transition(record.state, LifecycleState.ARCHITECTURE)
        self._transition(
            record.state, LifecycleState.ARCHITECTURE, "h2-prototype-walkthrough"
        )
        return CommandResult(command="h2", run=self.run_projection())

    def lock(self, request: LockRequest) -> CommandResult:
        """LOCK & BUILD: prove the projection, run the gates, transition.

        Ordering matters: the state match (409 STALE_STATE) and the
        Tier-1 hash proof (409 STALE_CONTRACT) come before the lock
        gates so a stale client can never mutate the contract.
        """
        record = self._require_state(request.expected_state)
        contract = self._contract
        if contract is None:
            raise StaleContractError(
                f"run {self._run_id!r} has no contract to lock"
            )
        canonical = tier1_canonical_hash(contract)
        if request.tier1_hash != canonical:
            raise StaleContractError(
                f"tier1_hash {request.tier1_hash!r} does not match the "
                f"current contract hash {canonical!r}"
            )
        assert_transition(record.state, LifecycleState.LOCKED)
        lock_contract(contract, now=self._now_utc())
        self._transition(record.state, LifecycleState.LOCKED, "lock-and-build")
        return CommandResult(command="lock", run=self.run_projection())

    def pause(self, request: CommandRequest) -> CommandResult:
        """Pause only a BUILDING run (mirrors the controller)."""
        record = self._require_state(request.expected_state)
        if record.state is not LifecycleState.BUILDING:
            raise InvalidTransition(
                f"only a BUILDING run can pause, run is {record.state.value}"
            )
        self._transition(record.state, LifecycleState.PAUSED, "api-pause")
        return CommandResult(command="pause", run=self.run_projection())

    def resume(self, request: CommandRequest) -> CommandResult:
        """Resume only a PAUSED run: PAUSED -> RESUMING -> BUILDING."""
        record = self._require_state(request.expected_state)
        if record.state is not LifecycleState.PAUSED:
            raise InvalidTransition(
                f"only a PAUSED run can resume, run is {record.state.value}"
            )
        self._transition(record.state, LifecycleState.RESUMING, "api-resume")
        self._transition(LifecycleState.RESUMING, LifecycleState.BUILDING, "api-resume")
        return CommandResult(command="resume", run=self.run_projection())


# ---------------------------------------------------------------------------
# WSGI application
# ---------------------------------------------------------------------------

StartResponse = Callable[..., None]
WSGIApplication = Callable[[dict[str, Any], StartResponse], list[bytes]]


class ApiRequestError(Exception):
    """Malformed HTTP request (bad JSON, wrong body shape)."""

    def __init__(self, error: str, detail: str) -> None:
        self.error = error
        self.detail = detail
        super().__init__(f"{error}: {detail}")


_STATUS_OK = "200 OK"
_STATUS_CONFLICT = "409 Conflict"


def _error_payload(error: str, detail: str, **extra: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {"error": error, "detail": detail}
    payload.update(extra)
    return payload


def _route(
    method: str,
    path: str,
    environ: dict[str, Any],
    service: CanvasService,
) -> tuple[str, dict[str, Any], list[tuple[str, str]]]:
    """Resolve one request to (status, payload, extra headers)."""
    get_handlers = {
        "/run": service.run_projection,
        "/trace": service.trace_projection,
        "/readiness": service.readiness_projection,
        "/contract": service.contract_projection,
    }
    post_handlers = {
        "/h1": (CommandRequest, service.confirm_h1),
        "/h2": (CommandRequest, service.confirm_h2),
        "/lock": (LockRequest, service.lock),
        "/pause": (CommandRequest, service.pause),
        "/resume": (CommandRequest, service.resume),
    }
    try:
        if method == "GET" and path in get_handlers:
            projection = get_handlers[path]()
            return (
                _STATUS_OK,
                redact_secrets(projection.model_dump(mode="json")),
                [],
            )
        if method == "POST" and path in post_handlers:
            request_model, handler = post_handlers[path]
            length = int(environ.get("CONTENT_LENGTH") or 0)
            try:
                parsed = json.loads(environ["wsgi.input"].read(length).decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                raise ApiRequestError("INVALID_JSON", str(exc))
            if not isinstance(parsed, dict):
                raise ApiRequestError(
                    "INVALID_REQUEST", "the request body must be a JSON object"
                )
            request = request_model.model_validate(parsed)
            result = handler(request)
            return (
                _STATUS_OK,
                redact_secrets(result.model_dump(mode="json")),
                [],
            )
        if path in get_handlers or path in post_handlers:
            allowed = []
            if path in get_handlers:
                allowed.append("GET")
            if path in post_handlers:
                allowed.append("POST")
            return (
                "405 Method Not Allowed",
                _error_payload(
                    "METHOD_NOT_ALLOWED",
                    f"method {method} is not allowed for {path}",
                ),
                [("Allow", ", ".join(allowed))],
            )
        return (
            "404 Not Found",
            _error_payload("NOT_FOUND", f"no route {method} {path}"),
            [],
        )
    except ApiRequestError as exc:
        return ("400 Bad Request", _error_payload(exc.error, exc.detail), [])
    except StaleStateError as exc:
        return (_STATUS_CONFLICT, _error_payload("STALE_STATE", str(exc)), [])
    except StaleContractError as exc:
        return (_STATUS_CONFLICT, _error_payload("STALE_CONTRACT", str(exc)), [])
    except UnknownRunError as exc:
        return ("404 Not Found", _error_payload("NOT_FOUND", str(exc)), [])
    except ConcurrentStateChange as exc:
        return (_STATUS_CONFLICT, _error_payload("STALE_STATE", str(exc)), [])
    except InvalidTransition as exc:
        return (
            "400 Bad Request",
            _error_payload("INVALID_TRANSITION", str(exc)),
            [],
        )
    except ContractLockError as exc:
        return (
            "400 Bad Request",
            _error_payload(
                "LOCK_DENIED",
                "; ".join(exc.reasons),
                reasons=list(exc.reasons),
            ),
            [],
        )
    except ValidationError as exc:
        return (
            "400 Bad Request",
            _error_payload(
                "INVALID_REQUEST",
                "request does not match the command schema",
                errors=[error["msg"] for error in exc.errors()],
            ),
            [],
        )
    except ValueError as exc:
        return (
            "400 Bad Request",
            _error_payload("INVALID_REQUEST", str(exc)),
            [],
        )


def create_app(service: CanvasService) -> WSGIApplication:
    """Build the WSGI application over a :class:`CanvasService`.

    Routes GET ``/run`` ``/trace`` ``/readiness`` ``/contract`` and POST
    ``/h1`` ``/h2`` ``/lock`` ``/pause`` ``/resume`` (trailing slashes
    normalized).  Every response body is JSON with ``Cache-Control:
    no-store``; responses are redacted (secret refs only, never raw
    secrets); 409 is reserved for the stale-state discipline
    (STALE_STATE / STALE_CONTRACT).
    """

    def application(
        environ: dict[str, Any], start_response: StartResponse
    ) -> list[bytes]:
        method = environ.get("REQUEST_METHOD", "GET")
        path = (environ.get("PATH_INFO") or "/").rstrip("/") or "/"
        status, payload, extra_headers = _route(
            method, path, environ, cast(CanvasService, service)
        )
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        headers = [
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body))),
            ("Cache-Control", "no-store"),
        ]
        headers.extend(extra_headers)
        start_response(status, headers)
        return [body]

    return application


def serve(service: CanvasService, host: str = "127.0.0.1", port: int = 8080) -> None:
    """Run the discovery API on a stdlib WSGI server (control plane)."""
    from wsgiref.simple_server import make_server

    make_server(host, port, create_app(service)).serve_forever()
