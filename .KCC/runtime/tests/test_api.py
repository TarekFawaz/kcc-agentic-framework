"""Behavioral tests for the autobuild discovery control-plane API.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.api` (KCC x Superpowers Hybrid
Framework Plan 06, Task 1; Design Spec v1.2; plan Global Constraints):

* GET ``run`` / ``trace`` / ``readiness`` / ``contract`` return REDACTED
  projections — secret references (``vault://``, ``env://``,
  ``keychain://``) are exposed, raw secret values NEVER appear in any
  projection;
* POST ``h1`` / ``h2`` / ``lock`` / ``pause`` / ``resume`` each carry
  ``expected_state`` and ``lock`` additionally carries ``tier1_hash``;
* ``STALE_STATE`` / ``STALE_CONTRACT`` respond HTTP 409 (the typed
  canvas client maps these to ``StaleProjectionError`` and never
  auto-retries LOCK);
* a valid LOCK is routed through the service (lock gates run, contract
  hash recorded, run state transitioned) while an invalid transition,
  malformed request or unknown run is refused fail-closed.

The WSGI app is exercised through ``create_app(service)`` with an
in-process request helper (no network, no test-client dependency).
"""

from __future__ import annotations

import io
import json
from datetime import datetime, timedelta, timezone
from typing import Any

import pytest
from pydantic import ValidationError

from kcc_autobuild.api import (
    CommandRequest,
    LockRequest,
    StoreCanvasService,
    create_app,
    redact_secrets,
)
from kcc_autobuild.contract import (
    AuthorityEnvelope,
    BuildContract,
    MoneyPolicy,
    ProviderEntry,
    RolloutClass,
    Tier1Invariants,
    Tier2Details,
    tier1_canonical_hash,
)
from kcc_autobuild.models import (
    DependencyStatus,
    LifecycleState,
    ReadinessStatus,
    RunRecord,
)
from kcc_autobuild.readiness import (
    EvidenceRecord,
    FallbackEntry,
    ReadinessItem,
    ReadinessPack,
)
from kcc_autobuild.store import RunStore
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode

NOW = datetime(2026, 1, 2, 12, 0, 0, tzinfo=timezone.utc)
TTL = timedelta(hours=4)

RAW_SECRET = "sk-live-raw-secret-value-0123456789abcdef"
"""A raw provider secret that must never appear in any projection."""

RAW_SECRET_ALT = "AKIAIOSFODNN7EXAMPLE"
"""A second raw secret shaped like an AWS access key id."""

REF_VAULT = "vault://acme/service/token"
REF_ENV = "env://deploy/credentials"
REF_KEYCHAIN = "keychain://acme/provider"


# ---------------------------------------------------------------------------
# Fixtures (a minimally valid, lockable run + contract by default)
# ---------------------------------------------------------------------------


def _trace() -> TraceGraph:
    """A trace where REQ-001 reaches both AC and PROD coverage."""
    return TraceGraph(
        nodes=[
            TraceNode(id="REQ-001", kind="requirement"),
            TraceNode(id="IMPL-01", kind="implementation"),
            TraceNode(id="AC-001", kind="acceptance"),
            TraceNode(id="PROD-001", kind="production_validation"),
        ],
        edges=[
            TraceEdge(source="REQ-001", target="IMPL-01"),
            TraceEdge(source="IMPL-01", target="AC-001"),
            TraceEdge(source="IMPL-01", target="PROD-001"),
        ],
    )


def _item(
    item_id: str = "IT-001",
    provider: str = "provider-a",
    status: ReadinessStatus = ReadinessStatus.READY,
    *,
    quota: str | None = None,
    principal: str | None = None,
    fallbacks: list[FallbackEntry] | None = None,
) -> ReadinessItem:
    return ReadinessItem(
        id=item_id,
        provider=provider,
        status=status,
        required_kinds=["identity"],
        evidence=[
            EvidenceRecord(
                kind="identity",
                result="pass",
                checked_at=NOW,
                resource_ids=["resource-1"],
                scopes=["scopes:read"],
                principal=principal,
                quota=quota,
            )
        ],
        fallbacks=[] if fallbacks is None else fallbacks,
        evidence_ttl=TTL,
    )


def _pack(items: list[ReadinessItem] | None = None) -> ReadinessPack:
    return ReadinessPack(items=[_item()] if items is None else items)


def _authority(**kwargs: object) -> AuthorityEnvelope:
    defaults: dict[str, object] = {
        "auto_provision_status": DependencyStatus.NOT_REQUIRED,
        "credential_refs": [REF_VAULT, REF_KEYCHAIN],
    }
    defaults.update(kwargs)
    return AuthorityEnvelope(**defaults)


def _money(**kwargs: object) -> MoneyPolicy:
    defaults: dict[str, object] = {"per_provider_caps": {"provider-a": 50_000}}
    defaults.update(kwargs)
    return MoneyPolicy(**defaults)


def _tier1(**kwargs: object) -> Tier1Invariants:
    defaults: dict[str, object] = {
        "product_scope": "internal CLI analysis tool",
        "non_goals": ["no public API"],
        "primary_user_journeys": ["run one analysis end to end"],
        "provider_whitelist": [ProviderEntry(provider="provider-a", paid=True)],
        "fallback_whitelist": [],
        "authority": _authority(),
        "money": _money(),
        "production_target": "https://app.internal.example.com",
        "rollout_class": RolloutClass.CANARY,
        "definition_of_done": (
            "analysis output is produced end to end and validated in staging"
        ),
        "definition_of_done_ids": ["PROD-001"],
    }
    defaults.update(kwargs)
    return Tier1Invariants(**defaults)


def _contract(**kwargs: object) -> BuildContract:
    defaults: dict[str, object] = {
        "tier1": _tier1(),
        "tier2": Tier2Details(staging_provider="provider-a"),
        "trace": _trace(),
        "readiness": _pack(),
    }
    defaults.update(kwargs)
    return BuildContract(**defaults)


def _run_id() -> str:
    return "RUN-001"


def _store(tmp_path, state: LifecycleState = LifecycleState.INTAKE) -> RunStore:
    store = RunStore(tmp_path / "run.db")
    store.create_run(
        RunRecord(run_id=_run_id(), title="canvas test run", created_at=NOW)
    )
    _advance(store, state)
    return store


def _advance(store: RunStore, target: LifecycleState) -> None:
    """Drive an INTAKE run forward to ``target`` through legal transitions."""
    order = [
        LifecycleState.DISCOVERY,
        LifecycleState.PROTOTYPE_REVIEW,
        LifecycleState.ARCHITECTURE,
        LifecycleState.DE_RISK,
        LifecycleState.READINESS,
        LifecycleState.CONTRACT_REVIEW,
        LifecycleState.LOCKED,
        LifecycleState.BUILDING,
    ]
    current = store.load_run(_run_id()).state
    for next_state in order:
        if current is target:
            break
        store.transition(
            _run_id(), expected=current, target=next_state, reason="fixture-advance"
        )
        current = next_state


def _service(tmp_path, **kwargs: object) -> StoreCanvasService:
    store = _store(
        tmp_path,
        state=kwargs.pop(  # type: ignore[arg-type]
            "state", LifecycleState.CONTRACT_REVIEW
        ),
    )
    trace = kwargs.pop("trace", _trace())  # type: ignore[arg-type]
    readiness = kwargs.pop("readiness", _pack())  # type: ignore[arg-type]
    contract = kwargs.pop("contract", _contract())  # type: ignore[arg-type]
    return StoreCanvasService(
        _run_id(),
        store,
        trace=trace,  # type: ignore[arg-type]
        readiness=readiness,  # type: ignore[arg-type]
        contract=contract,  # type: ignore[arg-type]
        now=NOW,
        **kwargs,
    )


def _app(tmp_path, **kwargs: object):
    return create_app(_service(tmp_path, **kwargs))


# ---------------------------------------------------------------------------
# WSGI request helper (in-process; no network socket)
# ---------------------------------------------------------------------------


def _call_raw(
    app: Any, method: str, path: str, raw_body: bytes = b""
) -> tuple[int, dict]:
    environ = {
        "REQUEST_METHOD": method,
        "PATH_INFO": path,
        "QUERY_STRING": "",
        "SERVER_NAME": "localhost",
        "SERVER_PORT": "8080",
        "SERVER_PROTOCOL": "HTTP/1.1",
        "wsgi.version": (1, 0),
        "wsgi.url_scheme": "http",
        "wsgi.input": io.BytesIO(raw_body),
        "wsgi.errors": io.StringIO(),
        "wsgi.multithread": False,
        "wsgi.multiprocess": False,
        "wsgi.run_once": False,
        "CONTENT_LENGTH": str(len(raw_body)),
        "CONTENT_TYPE": "application/json",
    }
    captured: dict[str, Any] = {}

    def start_response(status: str, headers: list, exc_info: Any = None) -> None:
        captured["status"] = status
        captured["headers"] = dict(headers)

    body_bytes = b"".join(app(environ, start_response))
    captured["_body"] = body_bytes
    return int(captured["status"].split()[0]), json.loads(body_bytes.decode("utf-8"))


def _call(app: Any, method: str, path: str, body: Any = None) -> tuple[int, dict]:
    raw = b"" if body is None else json.dumps(body).encode("utf-8")
    return _call_raw(app, method, path, raw)


def _text(response: dict) -> str:
    return json.dumps(response, sort_keys=True)


# ---------------------------------------------------------------------------
# GET projections (surface + redaction)
# ---------------------------------------------------------------------------


def test_run_projection_exposes_run_metadata(tmp_path) -> None:
    status, payload = _call(_app(tmp_path), "GET", "/run")
    assert status == 200
    assert payload["run_id"] == "RUN-001"
    assert payload["title"] == "canvas test run"
    assert payload["state"] == "CONTRACT_REVIEW"
    assert payload["created_at"] == NOW.isoformat().replace("+00:00", "Z")


def test_trace_projection_includes_server_owned_graph_and_coverage(
    tmp_path,
) -> None:
    status, payload = _call(_app(tmp_path), "GET", "/trace")
    assert status == 200
    assert [node["id"] for node in payload["nodes"]] == [
        "REQ-001",
        "IMPL-01",
        "AC-001",
        "PROD-001",
    ]
    assert payload["coverage"] == {"covered": ["REQ-001"], "orphans": []}


def test_readiness_projection_reports_evaluation(tmp_path) -> None:
    status, payload = _call(_app(tmp_path), "GET", "/readiness")
    assert status == 200
    assert payload["ready"] is True
    assert payload["coverage_ok"] is True
    assert payload["blockers"] == []
    assert payload["evidence_stale"] is False
    assert payload["items"][0]["item_id"] == "IT-001"
    assert payload["items"][0]["evidence_current"] is True


def test_contract_projection_mirrors_build_contract(tmp_path) -> None:
    status, payload = _call(_app(tmp_path), "GET", "/contract")
    assert status == 200
    assert payload["present"] is True
    assert payload["contract_version"] == "1.0"
    assert payload["tier1"]["product_scope"] == "internal CLI analysis tool"
    assert payload["tier1_hash"] == tier1_canonical_hash(_contract())
    assert payload["locked_at"] is None
    assert payload["contract_hash"] is None


def test_contract_projection_absent_when_no_contract(tmp_path) -> None:
    status, payload = _call(
        _app(tmp_path, contract=None, state=LifecycleState.INTAKE), "GET", "/contract"
    )
    assert status == 200
    assert payload["present"] is False
    assert payload["tier1"] is None
    assert payload["tier1_hash"] is None


# ---------------------------------------------------------------------------
# Core test 1: raw secrets are absent from projections (refs stay exposed)
# ---------------------------------------------------------------------------


def test_raw_secrets_absent_from_all_projections(tmp_path) -> None:
    """Secret refs are exposed; every raw secret value is redacted everywhere."""
    app = _app(
        tmp_path,
        state=LifecycleState.CONTRACT_REVIEW,
        readiness=_pack(
            [
                _item(
                    quota=f"quota hint: {RAW_SECRET}",
                    principal=REF_ENV,
                    fallbacks=[
                        FallbackEntry(
                            provider="provider-a",
                            trigger_scope="deploy",
                            allowed_function="deploy_app",
                            data_classes_allowed=["public"],
                            regions_allowed=["us-east-1"],
                            credential_ref=REF_VAULT,
                        )
                    ],
                )
            ]
        ),
    )
    for path in ("/run", "/trace", "/readiness", "/contract"):
        status, payload = _call(app, "GET", path)
        assert status == 200, path
        text = _text(payload)
        assert RAW_SECRET not in text, f"raw secret leaked through {path}"
        assert RAW_SECRET_ALT not in text, f"raw secret leaked through {path}"

    # The redacted marker is visible and the secret-REF values stay exposed.
    status, payload = _call(app, "GET", "/readiness")
    assert status == 200
    assert "[REDACTED]" in _text(payload)
    assert REF_VAULT in _text(payload)
    assert REF_ENV in _text(payload)
    status, payload = _call(app, "GET", "/contract")
    assert status == 200
    assert REF_VAULT in _text(payload)
    assert REF_KEYCHAIN in _text(payload)


def test_raw_secrets_absent_from_command_responses(tmp_path) -> None:
    """Command responses carry the same redaction as GET projections."""
    app = _app(tmp_path, state=LifecycleState.DISCOVERY)
    status, payload = _call(app, "POST", "/h1", {"expected_state": "DISCOVERY"})
    assert status == 200
    assert RAW_SECRET not in _text(payload)
    assert payload["command"] == "h1"
    assert payload["run"]["state"] == "PROTOTYPE_REVIEW"


def test_key_based_redaction_keeps_secret_references() -> None:
    """A value under a secret-ish key is redacted unless it is a secret ref."""
    data = {
        "api_key": "sk-raw-secret-abcdef0123456789",
        "credential_refs": [REF_VAULT, "env://deploy/credentials"],
        "nested": {"access_token": "AKIAIOSFODNN7EXAMPLE"},
        "label": "provider-a",
    }
    redacted = redact_secrets(data)
    assert redacted["api_key"] == "[REDACTED]"
    assert redacted["nested"]["access_token"] == "[REDACTED]"
    assert redacted["credential_refs"] == [REF_VAULT, "env://deploy/credentials"]
    assert redacted["label"] == "provider-a"


def test_redaction_preserves_non_secret_scalars_under_secret_keys() -> None:
    """Booleans/numbers/null are metadata, never secret material."""
    data = {
        "secret_reference_usage": False,
        "monitoring_setup": True,
        "credential_refs": [REF_VAULT],
        "secret": None,
    }
    assert redact_secrets(data) == {
        "secret_reference_usage": False,
        "monitoring_setup": True,
        "credential_refs": [REF_VAULT],
        "secret": None,
    }


def test_contract_projection_preserves_authority_flags_and_canonical_enum(
    tmp_path,
) -> None:
    """The projection keeps authority metadata and canonical enum names."""
    app = _app(
        tmp_path,
        contract=_contract(
            tier1=_tier1(
                authority=_authority(
                    auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED,
                    auto_provision_providers=["provider-a"],
                    approved_accounts=["prod-account"],
                    secret_reference_usage=True,
                )
            )
        ),
    )
    status, payload = _call(app, "GET", "/contract")
    assert status == 200
    authority = payload["tier1"]["authority"]
    assert authority["auto_provision_status"] == "AUTO_PROVISION_AUTHORIZED"
    assert authority["secret_reference_usage"] is True
    assert authority["monitoring_setup"] is False
    assert REF_VAULT in _text(payload)
    assert REF_KEYCHAIN in _text(payload)
    status, payload = _call(app, "GET", "/readiness")
    assert status == 200
    status, payload = _call(app, "GET", "/run")
    assert status == 200
    assert payload["state"] == "CONTRACT_REVIEW"


def test_value_based_redaction_hides_secrets_under_any_key() -> None:
    """Raw secret-shaped values are redacted even under generic keys."""
    redacted = redact_secrets({"note": f"token {RAW_SECRET} issued"})
    assert redacted["note"] == "[REDACTED]"


# ---------------------------------------------------------------------------
# Core test 2: stale contract hash => HTTP 409
# ---------------------------------------------------------------------------


def test_stale_contract_hash_returns_409(tmp_path) -> None:
    """LOCK with a tier1_hash that does not match the current contract is 409."""
    app = _app(tmp_path)
    status, payload = _call(
        app,
        "POST",
        "/lock",
        {"expected_state": "CONTRACT_REVIEW", "tier1_hash": "0" * 64},
    )
    assert status == 409
    assert payload["error"] == "STALE_CONTRACT"


def test_stale_state_returns_409(tmp_path) -> None:
    """A command whose expected_state does not match the run is 409."""
    app = _app(tmp_path, state=LifecycleState.CONTRACT_REVIEW)
    status, payload = _call(app, "POST", "/pause", {"expected_state": "BUILDING"})
    assert status == 409
    assert payload["error"] == "STALE_STATE"


def test_stale_state_blocks_lock_before_hash_check(tmp_path) -> None:
    """A stale expected_state refuses LOCK even when the hash would match."""
    contract = _contract()
    app = _app(tmp_path, state=LifecycleState.READINESS, contract=contract)
    status, payload = _call(
        app,
        "POST",
        "/lock",
        {
            "expected_state": "CONTRACT_REVIEW",
            "tier1_hash": tier1_canonical_hash(contract),
        },
    )
    assert status == 409
    assert payload["error"] == "STALE_STATE"


# ---------------------------------------------------------------------------
# Core test 3: a valid LOCK is routed through the service
# ---------------------------------------------------------------------------


def test_valid_lock_routed(tmp_path) -> None:
    """A valid LOCK executes the lock gates and transitions the run."""
    contract = _contract()
    tier1_hash = tier1_canonical_hash(contract)
    app = _app(tmp_path, contract=contract)
    status, payload = _call(
        app,
        "POST",
        "/lock",
        {"expected_state": "CONTRACT_REVIEW", "tier1_hash": tier1_hash},
    )
    assert status == 200
    assert payload["command"] == "lock"
    assert payload["accepted"] is True
    assert payload["run"]["state"] == "LOCKED"
    # The contract is now locked with the canonical hash.
    assert contract.contract_hash == tier1_hash
    assert contract.locked_at is not None
    status, payload = _call(app, "GET", "/contract")
    assert status == 200
    assert payload["contract_hash"] == tier1_hash
    assert payload["tier1_hash"] == tier1_hash
    # The run projection reflects the lock.
    status, payload = _call(app, "GET", "/run")
    assert status == 200
    assert payload["state"] == "LOCKED"
    assert payload["contract_hash"] == tier1_hash


def test_valid_lock_is_not_routed_twice(tmp_path) -> None:
    """A second LOCK with the old expected state is refused as stale (409)."""
    contract = _contract()
    tier1_hash = tier1_canonical_hash(contract)
    app = _app(tmp_path, contract=contract)
    first = _call(
        app,
        "POST",
        "/lock",
        {"expected_state": "CONTRACT_REVIEW", "tier1_hash": tier1_hash},
    )
    assert first[0] == 200
    second = _call(
        app,
        "POST",
        "/lock",
        {"expected_state": "CONTRACT_REVIEW", "tier1_hash": tier1_hash},
    )
    assert second[0] == 409
    assert second[1]["error"] == "STALE_STATE"


def test_lock_denied_when_contract_not_lockable(tmp_path) -> None:
    """An invalid state/readiness is a fail-closed 400, never a lock."""
    contract = _contract(readiness=_pack([_item(status=ReadinessStatus.BLOCKER)]))
    app = _app(tmp_path, contract=contract)
    status, payload = _call(
        app,
        "POST",
        "/lock",
        {
            "expected_state": "CONTRACT_REVIEW",
            "tier1_hash": tier1_canonical_hash(contract),
        },
    )
    assert status == 400
    assert payload["error"] == "LOCK_DENIED"
    assert payload["reasons"]


# ---------------------------------------------------------------------------
# H1 / H2 / PAUSE / RESUME commands
# ---------------------------------------------------------------------------


def test_h1_routed(tmp_path) -> None:
    app = _app(tmp_path, state=LifecycleState.DISCOVERY)
    status, payload = _call(app, "POST", "/h1", {"expected_state": "DISCOVERY"})
    assert status == 200
    assert payload["command"] == "h1"
    assert payload["run"]["state"] == "PROTOTYPE_REVIEW"


def test_h2_routed(tmp_path) -> None:
    app = _app(tmp_path, state=LifecycleState.PROTOTYPE_REVIEW)
    status, payload = _call(
        app, "POST", "/h2", {"expected_state": "PROTOTYPE_REVIEW"}
    )
    assert status == 200
    assert payload["command"] == "h2"
    assert payload["run"]["state"] == "ARCHITECTURE"


def test_pause_and_resume_routed(tmp_path) -> None:
    app = _app(tmp_path, state=LifecycleState.BUILDING)
    status, payload = _call(app, "POST", "/pause", {"expected_state": "BUILDING"})
    assert status == 200
    assert payload["command"] == "pause"
    assert payload["run"]["state"] == "PAUSED"
    status, payload = _call(app, "POST", "/resume", {"expected_state": "PAUSED"})
    assert status == 200
    assert payload["command"] == "resume"
    assert payload["run"]["state"] == "BUILDING"


def test_pause_rejected_when_run_not_building(tmp_path) -> None:
    app = _app(tmp_path, state=LifecycleState.CONTRACT_REVIEW)
    status, payload = _call(
        app, "POST", "/pause", {"expected_state": "CONTRACT_REVIEW"}
    )
    assert status == 400
    assert payload["error"] == "INVALID_TRANSITION"


def test_resume_rejected_when_run_not_paused(tmp_path) -> None:
    app = _app(tmp_path, state=LifecycleState.BUILDING)
    status, payload = _call(
        app, "POST", "/resume", {"expected_state": "BUILDING"}
    )
    assert status == 400
    assert payload["error"] == "INVALID_TRANSITION"


# ---------------------------------------------------------------------------
# Malformed requests and routing
# ---------------------------------------------------------------------------


def test_missing_expected_state_is_bad_request(tmp_path) -> None:
    status, payload = _call(_app(tmp_path), "POST", "/h1", {})
    assert status == 400
    assert payload["error"] == "INVALID_REQUEST"


def test_malformed_lock_hash_is_bad_request(tmp_path) -> None:
    status, payload = _call(
        _app(tmp_path),
        "POST",
        "/lock",
        {"expected_state": "CONTRACT_REVIEW", "tier1_hash": "not-a-hash"},
    )
    assert status == 400
    assert payload["error"] == "INVALID_REQUEST"


def test_malformed_json_body_is_bad_request(tmp_path) -> None:
    status, payload = _call_raw(_app(tmp_path), "POST", "/h1", b"{not json")
    assert status == 400
    assert payload["error"] == "INVALID_JSON"


def test_missing_body_is_bad_request(tmp_path) -> None:
    status, payload = _call(_app(tmp_path), "POST", "/h1")
    assert status == 400
    assert payload["error"] == "INVALID_JSON"


def test_unknown_run_is_not_found(tmp_path) -> None:
    unknown = create_app(
        StoreCanvasService("RUN-MISSING", RunStore(tmp_path / "other.db"))
    )
    status, payload = _call(unknown, "GET", "/run")
    assert status == 404
    assert payload["error"] == "NOT_FOUND"


def test_unknown_route_is_not_found(tmp_path) -> None:
    status, payload = _call(_app(tmp_path), "GET", "/nope")
    assert status == 404
    assert payload["error"] == "NOT_FOUND"


def test_wrong_method_is_not_allowed(tmp_path) -> None:
    status, payload = _call(_app(tmp_path), "POST", "/run")
    assert status == 405
    assert payload["error"] == "METHOD_NOT_ALLOWED"


def test_trailing_slash_normalized(tmp_path) -> None:
    status, _ = _call(_app(tmp_path), "GET", "/run/")
    assert status == 200


def test_lock_request_model_validates_tier1_hash() -> None:
    with pytest.raises(ValidationError):
        LockRequest(
            expected_state=LifecycleState.CONTRACT_REVIEW, tier1_hash="x"
        )


def test_command_request_preserves_canonical_enum_name() -> None:
    """Command enums round-trip; AUTO_PROVISION_AUTHORIZED is never renamed."""
    assert (
        DependencyStatus.AUTO_PROVISION_AUTHORIZED.value
        == "AUTO_PROVISION_AUTHORIZED"
    )
    request = CommandRequest(expected_state=LifecycleState.CONTRACT_REVIEW)
    assert request.expected_state is LifecycleState.CONTRACT_REVIEW
    assert request.model_dump(mode="json")["expected_state"] == "CONTRACT_REVIEW"
