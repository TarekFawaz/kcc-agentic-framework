"""Behavioral contract for the policy tool gate (sole mutation executor path).

Owned by ``test_tool_gate.py`` (see the KCC x Superpowers Hybrid Framework Plan
04, Task 6: Deterministic destructive-operation policy evaluator, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

:class:`~kcc_autobuild.tool_gate.PolicyToolGate` is the ONLY external /
data-mutation executor path: any provider, deploy or migration mutation
adapter receives the (already policy-bound) gate, never a raw client. For
every attempted execution the gate:

- evaluates the :class:`~kcc_autobuild.policy.Operation` against the signed
  ``PolicyBundle`` (policy.py), and
- logs a unique policy decision token / audit record BEFORE any executor
  invocation (audit first, then call), so every mutation is traceable to a
  single signed policy decision;
- ALLOWED -> invokes the wrapped executor exactly once, passing the decision
  token for correlation;
- DENIED -> raises :class:`PolicyDenied` and NEVER invokes the executor;
- AMBIGUOUS -> raises :class:`AmbiguousPolicy` back to KCC machine
  interpretation (spec 18/E4 path) -- a structured, machine-readable error,
  never a direct user prompt (spec 4.5 notifications-not-approvals; ruling
  R10: no extra approval gates), and never invokes the executor.
"""

from __future__ import annotations

import pytest

from kcc_autobuild.policy import (
    Operation,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    sign_policy_bundle,
)
from kcc_autobuild.tool_gate import (
    AmbiguousPolicy,
    PolicyAudit,
    PolicyDenied,
    PolicyGateError,
    PolicyToolGate,
)

SECRET = "unit-test-gate-secret"

ALLOW_DEPLOY_PUBLIC = PolicyRule("deploy", "prod/app", "PUBLIC", PolicyDecision.ALLOWED)
DENY_DEPLOY_PERSONAL = PolicyRule("deploy", "prod/app", "PERSONAL", PolicyDecision.DENIED)


def build_gate(
    rules,
    executor,
    *,
    sink=None,
    token_factory=None,
    secret=SECRET,
):
    evaluator = PolicyEvaluator(sign_policy_bundle(rules, secret), secret)
    return PolicyToolGate(
        evaluator,
        executor=executor,
        audit_sink=sink,
        token_factory=token_factory,
    )


class RecordingSink:
    """Audit sink that records every :class:`PolicyAudit`, in call order."""

    def __init__(self, events=None):
        self.records = []
        self.events = events if events is not None else []

    def record(self, audit):
        self.records.append(audit)
        self.events.append(("audit", audit.token))


class RecordingExecutor:
    """Stand-in for a raw provider/deploy/migration client (never callable
    directly by an adapter; only the gate may invoke it)."""

    def __init__(self, events=None):
        self.calls = []
        self.events = events if events is not None else []

    def __call__(self, operation, token):
        self.calls.append((operation, token))
        self.events.append(("executor", token))
        return f"done:{operation.operation}:{operation.resource}"


# --- ALLOWED: audit first, then the single executor invocation ---------------


def test_allowed_logs_audit_before_calling_executor():
    events = []
    executor = RecordingExecutor(events)
    sink = RecordingSink(events)
    deploy = Operation("deploy", "prod/app", "PUBLIC")
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC],
        executor,
        sink=sink,
        token_factory=lambda: "tok-1",
    )

    result = gate.execute(deploy)

    assert result == "done:deploy:prod/app"
    assert executor.calls == [(deploy, "tok-1")]
    # The audit record exists BEFORE the executor was invoked (no side effect
    # can occur without a prior policy decision record).
    assert events == [("audit", "tok-1"), ("executor", "tok-1")]
    assert len(sink.records) == 1
    audit = sink.records[0]
    assert audit.token == "tok-1"
    assert audit.decision is PolicyDecision.ALLOWED
    assert audit.operation == deploy
    assert gate.audits == [audit]


def test_allowed_without_sink_records_into_gate_audit_trail():
    executor = RecordingExecutor()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC], executor, token_factory=lambda: "tok-1"
    )
    gate.execute(Operation("deploy", "prod/app", "PUBLIC"))
    assert [audit.token for audit in gate.audits] == ["tok-1"]
    assert len(gate.audits) == 1


# --- DENIED: never calls the executor ---------------------------------------


def test_denied_never_calls_executor_and_raises():
    events = []
    executor = RecordingExecutor(events)
    sink = RecordingSink(events)
    gate = build_gate(
        [DENY_DEPLOY_PERSONAL],
        executor,
        sink=sink,
        token_factory=lambda: "tok-2",
    )

    with pytest.raises(PolicyDenied) as exc:
        gate.execute(Operation("deploy", "prod/app", "PERSONAL"))

    assert executor.calls == []
    assert events == [("audit", "tok-2")]  # decision logged, executor never touched
    denied = exc.value
    assert denied.token == "tok-2"
    assert denied.decision is PolicyDecision.DENIED
    assert denied.operation == Operation("deploy", "prod/app", "PERSONAL")
    assert isinstance(denied, PolicyGateError)
    assert sink.records[0].decision is PolicyDecision.DENIED


def test_denied_unlisted_operation_never_calls_executor():
    executor = RecordingExecutor()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC], executor, token_factory=lambda: "tok-3"
    )
    with pytest.raises(PolicyDenied):
        gate.execute(Operation("destroy", "prod/app", "PUBLIC"))
    assert executor.calls == []


# --- AMBIGUOUS: machine-interpretable escalation, never a user prompt --------


def test_ambiguous_raises_machine_readable_error_and_skips_executor():
    events = []
    executor = RecordingExecutor(events)
    sink = RecordingSink(events)
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC],
        executor,
        sink=sink,
        token_factory=lambda: "tok-4",
    )

    with pytest.raises(AmbiguousPolicy) as exc:
        gate.execute(Operation("deploy", "prod/app", "PERSONAL"))

    assert executor.calls == []
    assert events == [("audit", "tok-4")]
    ambiguous = exc.value
    # Structured machine-readable payload for KCC's exception path (spec 18:
    # E4 -- irreversible/ambiguous action outside approved policy). It is an
    # exception on the machine path -- there is no interactive prompt.
    assert ambiguous.token == "tok-4"
    assert ambiguous.decision is PolicyDecision.AMBIGUOUS
    assert ambiguous.operation == Operation("deploy", "prod/app", "PERSONAL")
    assert isinstance(ambiguous, PolicyGateError)
    assert isinstance(ambiguous, RuntimeError)
    assert sink.records[0].decision is PolicyDecision.AMBIGUOUS
    assert gate.audits[0].decision is PolicyDecision.AMBIGUOUS


def test_ambiguous_escalation_matches_failure_classification_contract():
    # The policy layer feeds the failure classifier's CONTRACT class: the
    # structured fields let the controller map AMBIGUOUS to a policy/contract
    # failure without asking the user (R10: no extra approval gates).
    from kcc_autobuild.failure_classifier import FailureEvidence, classify
    from kcc_autobuild.models import FailureClass

    gate = build_gate([ALLOW_DEPLOY_PUBLIC], RecordingExecutor())
    with pytest.raises(AmbiguousPolicy) as exc:
        gate.execute(Operation("deploy", "prod/app", "PERSONAL"))
    evidence = FailureEvidence(
        message=f"policy ambiguous: {exc.value.token} {exc.value.operation}"
    )
    assert classify(evidence) is FailureClass.CONTRACT


# --- Unique decision tokens --------------------------------------------------


def test_decision_tokens_are_unique_per_execution():
    executor = RecordingExecutor()
    gate = build_gate([ALLOW_DEPLOY_PUBLIC], executor)
    deploy = Operation("deploy", "prod/app", "PUBLIC")
    gate.execute(deploy)
    gate.execute(deploy)
    tokens = [audit.token for audit in gate.audits]
    assert len(tokens) == 2
    assert len(set(tokens)) == 2  # unique: every attempt gets its own audit
    assert [token for _, token in executor.calls] == tokens


# --- Audit-before-call holds even when the executor itself fails -------------


def test_audit_recorded_before_executor_exception_propagates():
    def exploding_executor(operation, token):
        raise RuntimeError(f"boom {token}")

    sink = RecordingSink()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC],
        exploding_executor,
        sink=sink,
        token_factory=lambda: "tok-5",
    )
    with pytest.raises(RuntimeError, match="boom tok-5"):
        gate.execute(Operation("deploy", "prod/app", "PUBLIC"))
    # The policy decision was still logged before the (failed) call.
    assert [audit.token for audit in sink.records] == ["tok-5"]
    assert sink.records[0].decision is PolicyDecision.ALLOWED


# --- Mutation adapters receive the gate, never a raw client -----------------


class _GatedMutationAdapter:
    """Test stand-in for the provider/deploy/migration mutation adapters.

    They are constructed with the already-policy-bound
    :class:`PolicyToolGate` -- a raw client is rejected outright, so the gate
    stays the ONLY external/data-mutation executor path.
    """

    def __init__(self, gate):
        if not isinstance(gate, PolicyToolGate):
            raise TypeError(
                "mutation adapters receive a PolicyToolGate, not a raw client"
            )
        self._gate = gate

    def apply(self, operation):
        return self._gate.execute(operation)


class ProviderMutationAdapter(_GatedMutationAdapter):
    """Provider mutation adapter (receives the gate)."""


class DeployMutationAdapter(_GatedMutationAdapter):
    """Deployment mutation adapter (receives the gate)."""


class MigrationMutationAdapter(_GatedMutationAdapter):
    """Database migration adapter (receives the gate)."""


def test_provider_deploy_migration_adapters_route_through_the_gate():
    raw_client = RecordingExecutor()  # in production this never leaves the gate
    sink = RecordingSink()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC], raw_client, sink=sink, token_factory=lambda: f"tok-{len(sink.records) + 1}"
    )
    provider = ProviderMutationAdapter(gate)
    deploy = DeployMutationAdapter(gate)
    migration = MigrationMutationAdapter(gate)

    provider_result = provider.apply(Operation("deploy", "prod/app", "PUBLIC"))
    deploy_result = deploy.apply(Operation("deploy", "prod/app", "PUBLIC"))
    migration_result = migration.apply(Operation("deploy", "prod/app", "PUBLIC"))

    assert provider_result == deploy_result == migration_result == "done:deploy:prod/app"
    # The raw client was reached exactly three times, always via the gate,
    # each with its own decision token.
    assert len(raw_client.calls) == 3
    assert len(sink.records) == 3
    assert len(set(audit.token for audit in sink.records)) == 3


def test_adapter_rejects_a_raw_client():
    raw_client = RecordingExecutor()
    with pytest.raises(TypeError, match="not a raw client"):
        DeployMutationAdapter(raw_client)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="not a raw client"):
        ProviderMutationAdapter(raw_client)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="not a raw client"):
        MigrationMutationAdapter(raw_client)  # type: ignore[arg-type]


def test_adapter_denied_and_ambiguous_never_reach_the_raw_client():
    raw_client = RecordingExecutor()
    gate = build_gate([ALLOW_DEPLOY_PUBLIC, DENY_DEPLOY_PERSONAL], raw_client)
    deploy = DeployMutationAdapter(gate)
    with pytest.raises(PolicyDenied):
        deploy.apply(Operation("deploy", "prod/app", "PERSONAL"))
    with pytest.raises(AmbiguousPolicy):
        deploy.apply(Operation("deploy", "staging/app", "PUBLIC"))
    assert raw_client.calls == []


# --- Gate construction and argument validation -------------------------------


def test_gate_rejects_non_callable_executor():
    evaluator = PolicyEvaluator(sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET)
    with pytest.raises(TypeError):
        PolicyToolGate(evaluator, executor="not-callable")  # type: ignore[arg-type]


def test_gate_rejects_non_evaluator():
    with pytest.raises(TypeError):
        PolicyToolGate(evaluator="not-an-evaluator", executor=lambda op, token: None)  # type: ignore[arg-type]


def test_gate_rejects_non_operation_without_auditing():
    executor = RecordingExecutor()
    gate = build_gate([ALLOW_DEPLOY_PUBLIC], executor)
    with pytest.raises(TypeError):
        gate.execute("deploy")  # type: ignore[arg-type]
    assert executor.calls == []
    assert gate.audits == []


def test_gate_audit_is_a_frozen_value_object():
    audit = PolicyAudit(token="tok-9", operation=Operation("deploy", "prod/app", "PUBLIC"), decision=PolicyDecision.ALLOWED)
    assert audit == PolicyAudit(token="tok-9", operation=Operation("deploy", "prod/app", "PUBLIC"), decision=PolicyDecision.ALLOWED)
    with pytest.raises(Exception):
        audit.token = "tok-10"  # type: ignore[misc]


# =============================================================================
# Plan 08, Task 5 -- Hardened DSH profile + Cordis mutation guard.
# -----------------------------------------------------------------------------
# The DeepSeek Harness workers get a fail-closed exact tool allowlist, a
# canonical path confinement for governed writes, and the CLI internal
# policy gate commands (``gate-write`` / ``gate-exec``) that the Cordis
# wrapper tools call with the untrusted operation request on stdin.  KCC
# reloads the durable run, rejects stale leases, verifies the signed
# policy bundle, and only then lets PolicyToolGate mint/audit a decision
# token and run the executor.  Contract:
#   .superpowers/bootstrap/plans/2026-08-27-08-harness-capability-
#     deepseek-adapter.task-contracts.md (Task 5)
# =============================================================================

import json
import stat
from datetime import datetime, timezone
from pathlib import Path

from typer.testing import CliRunner

from kcc_autobuild.cli import app  # noqa: E402
from kcc_autobuild.dsh_gate import (  # noqa: E402
    DSH_ALLOWED_TOOLS,
    DSH_DENIED_PREFIXES,
    DSH_DENIED_TOOLS,
    DSH_NATIVE_ALLOWED_TOOLS,
    DshToolGate,
    GateDecision,
    GateOperation,
    GatePathError,
    GateRequest,
    confine_path,
    gate_audit_path,
    load_policy_bundle,
    provision_gate_policy,
    tool_allowed,
)
from kcc_autobuild.leases import LeaseStore  # noqa: E402
from kcc_autobuild.models import RunRecord  # noqa: E402
from kcc_autobuild.policy import (  # noqa: E402
    POLICY_BUNDLE_FORMAT,
    PolicyBundle,
)
from kcc_autobuild.store import RunStore  # noqa: E402

T5_RUN_ID = "RUN-001"
T5_TASK_ID = "TASK-021"
T5_NOW = datetime(2026, 8, 28, 18, 0, 0, tzinfo=timezone.utc)

T5_WRITE_TERMS = PolicyRule("write", "src/kcc.py", "PUBLIC", PolicyDecision.ALLOWED)
T5_EXEC_TERMS = PolicyRule("exec", "pytest", "PUBLIC", PolicyDecision.ALLOWED)
T5_SECRET = "dsh-gate-test-secret"


def _gate(repo_root, *, rules=(T5_WRITE_TERMS, T5_EXEC_TERMS), secret=T5_SECRET, **kwargs):
    """One DshToolGate over a freshly signed bundle (or overridden bundle)."""
    bundle = kwargs.pop("bundle", sign_policy_bundle(rules, secret))
    return DshToolGate(
        repo_root=repo_root,
        bundle=bundle,
        secret=secret,
        now=T5_NOW,
        **kwargs,
    )


def _make_run(repo_root, task_id=T5_TASK_ID, *, now=T5_NOW):
    """Create the run DB + one live lease bound to ``task_id``."""
    store = RunStore(gate_audit_path(repo_root, T5_RUN_ID).parent / "run.db")
    store.create_run(
        RunRecord(run_id=T5_RUN_ID, title="dsh gate demo", created_at=now)
    )
    leases = LeaseStore(store)
    lease = leases.claim(T5_RUN_ID, task_id, now=now, workspace_id="WS-1")
    store.close()
    return lease


def _write_request(task_id=T5_TASK_ID, lease_id=None, generation=1, **operation):
    op = {"kind": "write", "path": "src/kcc.py", "content": "print('hi')\n", **operation}
    return GateRequest(
        run_id=T5_RUN_ID,
        task_id=task_id,
        lease_id=lease_id or f"LEASE-{T5_RUN_ID}-{task_id}-{generation}",
        generation=generation,
        tool="kcc_policy_write",
        operation=GateOperation(**op),
    )


def _exec_request(task_id=T5_TASK_ID, lease_id=None, generation=1, **operation):
    op = {"kind": "exec", "command": "pytest", "args": ["-q"], **operation}
    return GateRequest(
        run_id=T5_RUN_ID,
        task_id=task_id,
        lease_id=lease_id or f"LEASE-{T5_RUN_ID}-{task_id}-{generation}",
        generation=generation,
        tool="kcc_policy_exec",
        operation=GateOperation(**op),
    )


class RecordingRunner:
    """Stand-in for the process runner (never invoked by a denied call)."""

    def __init__(self):
        self.calls = []

    def __call__(self, argv, cwd, env):
        self.calls.append((list(argv), Path(cwd), dict(env)))
        return _ShellResult(returncode=0, stdout="ok", stderr="", error=None)


class _ShellResult:
    def __init__(self, *, returncode, stdout, stderr, error):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.error = error


# --- Exact fail-closed tool allowlist ---------------------------------------


def test_dsh_allowlist_is_exactly_native_read_only_plus_kcc_wrappers():
    assert DSH_ALLOWED_TOOLS == frozenset(
        {
            "read", "read_image", "glob", "grep", "todo_write",
            "kcc_policy_exec", "kcc_policy_write", "kcc_harness_status",
        }
    )
    assert DSH_NATIVE_ALLOWED_TOOLS == frozenset(
        {"read", "read_image", "glob", "grep", "todo_write"}
    )


def test_dsh_allowlist_has_no_controller_or_resume_wrappers():
    # KCC owns controller/status/resume: the wrappers are exactly the two
    # governed mutation tools plus the read-only status probe.
    assert "kcc_controller" not in DSH_ALLOWED_TOOLS
    assert "kcc_resume" not in DSH_ALLOWED_TOOLS
    assert "kcc_harness_controller" not in DSH_ALLOWED_TOOLS
    assert DSH_ALLOWED_TOOLS - DSH_NATIVE_ALLOWED_TOOLS == frozenset(
        {"kcc_policy_exec", "kcc_policy_write", "kcc_harness_status"}
    )


def test_dsh_tool_allowed_accepts_only_the_exact_allowlist():
    for name in DSH_ALLOWED_TOOLS:
        assert tool_allowed(name) is True
        assert tool_allowed(" " + name) is False  # exact match only
        assert tool_allowed(name.upper()) is False


@pytest.mark.parametrize(
    "denied",
    [
        "bash",
        "pwsh",
        "terminal",
        "write",
        "edit",
        "str_replace",
        "str_replace_editor",
        "job_kill",
        "web_search",
        "web_fetch",
        "create_goal",
        "update_goal",
        "goal",
        "workflow",
        "ralph",
        "run_code",
        "skill",
        "memory_recall",
        "cordis/dynamic-package",
        "exit_plan_mode",
        "subagent",
        "subagent_fork",
        "subagent_list_agents",
        "cordis_inspect_query",
        "cordis_dynamic_package",
        "mcp__server",
        "mcp__tools_call",
        "completely-unknown-tool",
        "",
    ],
)
def test_dsh_tool_allowed_fails_closed_on_raw_or_unknown_tools(denied):
    assert tool_allowed(denied) is False


def test_dsh_denied_prefixes_cover_subagent_cordis_and_mcp():
    assert "subagent" in DSH_DENIED_PREFIXES
    assert "cordis_" in DSH_DENIED_PREFIXES
    assert "mcp__" in DSH_DENIED_PREFIXES
    for prefix in DSH_DENIED_PREFIXES:
        assert tool_allowed(prefix + "anything") is False


def test_dsh_denied_exact_set_covers_the_raw_mutation_tools():
    for name in (
        "bash", "pwsh", "terminal", "write", "edit", "str_replace",
        "job_kill", "web_search", "web_fetch", "create_goal", "update_goal",
        "workflow", "ralph", "run_code",
    ):
        assert name in DSH_DENIED_TOOLS


# --- Canonical path confinement under the session cwd -----------------------


def test_confine_path_accepts_relative_targets_under_cwd(tmp_path):
    confined = confine_path(tmp_path, "src/kcc.py")
    assert confined.is_relative_to(tmp_path)
    assert confined == tmp_path / "src/kcc.py"


def test_confine_path_accepts_dot_prefix_and_normalizes(tmp_path):
    (tmp_path / "src").mkdir()
    confined = confine_path(tmp_path, "./src/kcc.py")
    assert confined == tmp_path / "src" / "kcc.py"


@pytest.mark.parametrize("target", ["/etc/passwd", "/home/user/x.py", "//host/share"])
def test_confine_path_rejects_absolute_targets(tmp_path, target):
    with pytest.raises(GatePathError):
        confine_path(tmp_path, target)


@pytest.mark.parametrize(
    "target", ["..", "../x.py", "a/../../x.py", "src/../x.py", "..", "a/..", "src/../.."]
)
def test_confine_path_rejects_parent_or_sibling_escape(tmp_path, target):
    with pytest.raises(GatePathError):
        confine_path(tmp_path, target)


def test_confine_path_rejects_symlink_escape(tmp_path):
    outside = tmp_path.parent / f"dsh-gate-outside-{tmp_path.name}"
    outside.mkdir(exist_ok=True)
    try:
        (outside / "secret.txt").write_text("secret", encoding="utf-8")
        (tmp_path / "escape-dir").symlink_to(outside, target_is_directory=True)
        (tmp_path / "escape-file.txt").symlink_to(outside / "secret.txt")
        with pytest.raises(GatePathError):
            confine_path(tmp_path, "escape-dir/secret.txt")
        with pytest.raises(GatePathError):
            confine_path(tmp_path, "escape-file.txt")
        # A symlink that stays INSIDE the cwd is fine.
        (tmp_path / "link.txt").symlink_to(tmp_path / "real.txt")
        assert confine_path(tmp_path, "link.txt") is not None
    finally:
        (outside / "secret.txt").unlink(missing_ok=True)
        outside.rmdir()


def test_confine_path_anchors_on_the_cwd_realpath(tmp_path, monkeypatch):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "linked"
    link.symlink_to(real, target_is_directory=True)
    confined = confine_path(link, "a/b.py")
    assert confined == real / "a" / "b.py"
    assert confined.is_relative_to(real)


@pytest.mark.parametrize("target", ["*.py", "src/[ab].py", "a/{x,y}.py", "a/?.py", "../*.py"])
def test_confine_path_rejects_escaping_glob_patterns(tmp_path, target):
    with pytest.raises(GatePathError):
        confine_path(tmp_path, target)


@pytest.mark.parametrize("target", ["", "  ", "a\x00b", "a/b\x00c"])
def test_confine_path_rejects_blank_and_nul_targets(tmp_path, target):
    with pytest.raises(GatePathError):
        confine_path(tmp_path, target)


# --- Gate request model (untrusted stdin payload) ----------------------------


def test_gate_request_rejects_unknown_tool():
    with pytest.raises(Exception):
        GateRequest(
            run_id=T5_RUN_ID, task_id=T5_TASK_ID,
            lease_id=f"LEASE-{T5_RUN_ID}-{T5_TASK_ID}-1", generation=1,
            tool="raw_bash", operation=GateOperation(kind="write", path="x", content="y"),
        )


def test_gate_request_rejects_write_without_path_or_content():
    with pytest.raises(Exception):
        GateOperation(kind="write", path="")
    with pytest.raises(Exception):
        GateOperation(kind="write", content="")


def test_gate_request_rejects_exec_without_command():
    with pytest.raises(Exception):
        GateOperation(kind="exec", command="")
    with pytest.raises(Exception):
        GateOperation(kind="exec", args=["-q"])


def test_gate_request_rejects_path_like_exec_command():
    # A governed exec names a program, never a path (no shell, no traversal).
    with pytest.raises(Exception):
        GateOperation(kind="exec", command="../../bin/malicious")
    with pytest.raises(Exception):
        GateOperation(kind="exec", command="C:\\Windows\\System32\\cmd.exe")


def test_gate_request_rejects_nonpositive_generation_and_version():
    with pytest.raises(Exception):
        GateRequest(
            run_id=T5_RUN_ID, task_id=T5_TASK_ID,
            lease_id=f"LEASE-{T5_RUN_ID}-{T5_TASK_ID}-0", generation=0,
            tool="kcc_policy_write",
            operation=GateOperation(kind="write", path="x", content="y"),
        )
    with pytest.raises(Exception):
        GateRequest(
            run_id=T5_RUN_ID, task_id=T5_TASK_ID,
            lease_id=f"LEASE-{T5_RUN_ID}-{T5_TASK_ID}-1", generation=1, version=99,
            tool="kcc_policy_write",
            operation=GateOperation(kind="write", path="x", content="y"),
        )


def test_gate_request_rejects_exec_args_that_are_not_strings():
    with pytest.raises(Exception):
        GateOperation(kind="exec", command="pytest", args=[1, 2])


# --- DshToolGate pipeline: run -> lease -> bundle -> gate -> executor --------


def test_gate_write_allowed_writes_file_and_audits_decision_token(tmp_path):
    lease = _make_run(tmp_path)
    gate = _gate(tmp_path)
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert isinstance(decision, GateDecision)
    assert decision.allowed is True
    assert decision.tool == "kcc_policy_write"
    assert decision.token and len(decision.token) == 32
    assert (tmp_path / "src/kcc.py").read_text(encoding="utf-8") == "print('hi')\n"
    assert decision.outcome == {
        "operation": "create",
        "before": None,
        "after": "print('hi')\n",
    }
    # The audit record exists and carries the same decision token.
    assert [audit.token for audit in gate.audits] == [decision.token]
    assert gate.audits[0].decision is PolicyDecision.ALLOWED
    assert gate.audits[0].operation == Operation("write", "src/kcc.py", "PUBLIC")
    # The durable audit jsonl contains the record.
    audit_lines = gate_audit_path(tmp_path, T5_RUN_ID).read_text(
        encoding="utf-8"
    ).splitlines()
    assert len(audit_lines) == 1
    assert json.loads(audit_lines[0])["token"] == decision.token
    assert json.loads(audit_lines[0])["decision"] == "ALLOWED"


def test_gate_write_second_call_detects_update(tmp_path):
    lease = _make_run(tmp_path)
    gate = _gate(tmp_path)
    gate.handle(_write_request(lease_id=lease.lease_id))
    second = gate.handle(
        _write_request(lease_id=lease.lease_id, content="print('again')\n")
    )
    assert second.allowed is True
    assert second.outcome["operation"] == "update"
    assert second.outcome["before"] == "print('hi')\n"
    assert len(gate.audits) == 2
    assert len({audit.token for audit in gate.audits}) == 2  # unique tokens


def test_gate_write_denied_by_rule_never_touches_the_file(tmp_path):
    lease = _make_run(tmp_path)
    gate = _gate(
        tmp_path,
        rules=[PolicyRule("write", "src/kcc.py", "PUBLIC", PolicyDecision.DENIED)],
    )
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert decision.token is not None  # audited even when denied
    assert not (tmp_path / "src/kcc.py").exists()
    assert gate.audits[0].decision is PolicyDecision.DENIED


def test_gate_write_ambiguous_classification_denies_fail_closed(tmp_path):
    # Rule exists for "write" but under another data class: AMBIGUOUS (never
    # a prompt -- a machine-readable denial) and never executes.
    lease = _make_run(tmp_path)
    gate = _gate(
        tmp_path,
        rules=[PolicyRule("write", "src/kcc.py", "PERSONAL", PolicyDecision.ALLOWED)],
    )
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert decision.token is not None
    assert "AMBIGUOUS" in (decision.reason or "")
    assert not (tmp_path / "src/kcc.py").exists()


def test_gate_write_rejects_escaping_path_before_any_policy_or_write(tmp_path):
    lease = _make_run(tmp_path)
    outside = tmp_path.parent / f"dsh-gate-escape-{tmp_path.name}"
    outside.mkdir(exist_ok=True)
    try:
        gate = _gate(
            tmp_path,
            rules=[
                PolicyRule("write", "../escape.txt", "PUBLIC", PolicyDecision.ALLOWED)
            ],
        )
        decision = gate.handle(
            _write_request(
                lease_id=lease.lease_id,
                path="../escape.txt",
                content="escaped",
            )
        )
        assert decision.allowed is False
        assert "path" in (decision.reason or "").lower()
        assert gate.audits == []  # confinement fails BEFORE any policy gate
        assert not (outside / "escape.txt").exists()
        assert not (tmp_path.parent / "escape.txt").exists()
    finally:
        outside.rmdir()


def test_gate_write_rejects_stale_lease(tmp_path):
    store = RunStore(gate_audit_path(tmp_path, T5_RUN_ID).parent / "run.db")
    store.create_run(
        RunRecord(run_id=T5_RUN_ID, title="demo", created_at=T5_NOW)
    )
    leases = LeaseStore(store)
    lease = leases.claim(T5_RUN_ID, T5_TASK_ID, now=T5_NOW, workspace_id="WS-1")
    leases.fence(lease.lease_id)
    store.close()
    gate = _gate(tmp_path)
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert decision.token is None
    assert "lease" in (decision.reason or "").lower()
    assert not (tmp_path / "src/kcc.py").exists()


def test_gate_write_rejects_lease_bound_to_another_task(tmp_path):
    lease = _make_run(tmp_path, task_id="OTHER-TASK")
    gate = _gate(tmp_path)
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert "task" in (decision.reason or "").lower()
    assert not (tmp_path / "src/kcc.py").exists()


def test_gate_write_rejects_missing_run(tmp_path):
    # No coordination/autobuild/RUN-001/run.db at all.
    gate = _gate(tmp_path)
    decision = gate.handle(_write_request(lease_id="LEASE-RUN-001-TASK-021-1"))
    assert decision.allowed is False
    assert "run" in (decision.reason or "").lower()
    assert not (tmp_path / "src/kcc.py").exists()


def test_gate_write_rejects_unsigned_policy_bundle(tmp_path):
    lease = _make_run(tmp_path)
    unsigned = PolicyBundle(
        format=POLICY_BUNDLE_FORMAT,
        rules=(T5_WRITE_TERMS,),
        signature=None,
    )
    gate = _gate(tmp_path, bundle=unsigned)
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert "polic" in (decision.reason or "").lower()
    assert not (tmp_path / "src/kcc.py").exists()


def test_gate_write_rejects_tampered_bundle_file(tmp_path):
    lease = _make_run(tmp_path)
    bundle_dir = tmp_path / "gate"
    bundle_path, secret_path = provision_gate_policy(bundle_dir, rules=[T5_WRITE_TERMS])
    # Tamper: change a rule, keep the old signature.
    data = json.loads(bundle_path.read_text(encoding="utf-8"))
    for rule in data["rules"]:
        if rule["resource"] == "src/kcc.py":
            rule["decision"] = "DENIED"
    bundle_path.write_text(json.dumps(data, sort_keys=True), encoding="utf-8")
    loaded = load_policy_bundle(bundle_path)
    gate = _gate(tmp_path, bundle=loaded, secret=secret_path.read_text(encoding="utf-8").strip())
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert "signature" in (decision.reason or "").lower()
    assert not (tmp_path / "src/kcc.py").exists()


def test_gate_write_fails_closed_without_policy_secret(tmp_path):
    lease = _make_run(tmp_path)
    gate = DshToolGate(
        repo_root=tmp_path,
        bundle=sign_policy_bundle((T5_WRITE_TERMS,), T5_SECRET),
        secret=None,
        secret_file=tmp_path / "missing.secret",
        now=T5_NOW,
    )
    decision = gate.handle(_write_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert "secret" in (decision.reason or "").lower()
    assert not (tmp_path / "src/kcc.py").exists()


def test_gate_exec_allowed_runs_exact_argv_without_shell(tmp_path):
    lease = _make_run(tmp_path)
    runner = RecordingRunner()
    gate = _gate(tmp_path, runner=runner)
    decision = gate.handle(_exec_request(lease_id=lease.lease_id))
    assert decision.allowed is True
    assert decision.outcome["returncode"] == 0
    assert len(runner.calls) == 1
    argv, cwd, _env = runner.calls[0]
    assert argv == ["pytest", "-q"]  # list argv: no shell, no interpolation
    assert cwd == Path(tmp_path)
    assert gate.audits[0].operation == Operation("exec", "pytest", "PUBLIC")


def test_gate_exec_denied_command_never_runs(tmp_path):
    lease = _make_run(tmp_path)
    runner = RecordingRunner()
    gate = _gate(
        tmp_path,
        rules=[PolicyRule("exec", "git", "PUBLIC", PolicyDecision.ALLOWED)],
        runner=runner,
    )
    decision = gate.handle(_exec_request(lease_id=lease.lease_id))
    assert decision.allowed is False
    assert runner.calls == []
    assert decision.token is not None  # audited, never executed


def test_gate_exec_sanitizes_secret_environment_variables(tmp_path, monkeypatch):
    lease = _make_run(tmp_path)
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "aws-secret")
    monkeypatch.setenv("OPENROUTER_API_KEY", "route-key")
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    runner = RecordingRunner()
    gate = _gate(tmp_path, runner=runner)
    decision = gate.handle(_exec_request(lease_id=lease.lease_id))
    assert decision.allowed is True
    env = runner.calls[0][2]
    assert "AWS_SECRET_ACCESS_KEY" not in env
    assert "OPENROUTER_API_KEY" not in env
    assert env["PATH"] == "/usr/bin:/bin"
    assert "AWS_SECRET_ACCESS_KEY" not in " ".join(
        f"{k}={v}" for k, v in env.items()
    )


def test_gate_exec_rejects_metacharacter_tampering_in_argv(tmp_path):
    # argv is passed as a list (no shell); the model cannot smuggle a
    # shell metacharacter payload through the request model.
    with pytest.raises(Exception):
        GateOperation(kind="exec", command="pytest", args=["-q; rm -rf /"])
    with pytest.raises(Exception):
        GateOperation(kind="exec", command="pytest", args=["$(whoami)"])


# --- Provisioning: signed bundle + owner-only secret -----------------------


def test_provision_gate_policy_writes_signed_bundle_and_0600_secret(tmp_path):
    bundle_path, secret_path = provision_gate_policy(
        tmp_path / "gate", rules=[T5_WRITE_TERMS]
    )
    assert bundle_path.is_file() and secret_path.is_file()
    mode = stat.S_IMODE(secret_path.stat().st_mode)
    assert mode & 0o077 == 0  # owner-only
    bundle = load_policy_bundle(bundle_path)
    secret = secret_path.read_text(encoding="utf-8").strip()
    evaluator = PolicyEvaluator(bundle, secret)
    assert evaluator.evaluate(Operation("write", "src/kcc.py", "PUBLIC")) is (
        PolicyDecision.ALLOWED
    )


def test_provision_gate_policy_defaults_to_fail_closed_empty_policy(tmp_path):
    # A freshly provisioned gate denies every operation until KCC signs the
    # real policy: no implicit allowance.
    bundle_path, secret_path = provision_gate_policy(tmp_path / "gate")
    bundle = load_policy_bundle(bundle_path)
    evaluator = PolicyEvaluator(bundle, secret_path.read_text(encoding="utf-8").strip())
    assert evaluator.evaluate(Operation("exec", "pytest", "PUBLIC")) is PolicyDecision.DENIED
    assert evaluator.evaluate(Operation("write", "src/kcc.py", "PUBLIC")) is PolicyDecision.DENIED


# --- CLI internal gate-exec / gate-write (stdin request) --------------------


def _cli_run(tmp_path, command, payload, bundle_path, secret_path):
    runner = CliRunner()
    return runner.invoke(
        app,
        [command, "--bundle", str(bundle_path), "--secret-file", str(secret_path)],
        input=json.dumps(payload),
    )


def test_cli_gate_write_reads_stdin_and_prints_deterministic_json(
    tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    lease = _make_run(tmp_path)
    bundle_path, secret_path = provision_gate_policy(
        tmp_path / "gate", rules=[T5_WRITE_TERMS]
    )
    result = _cli_run(
        tmp_path,
        "gate-write",
        _write_request(lease_id=lease.lease_id).model_dump(mode="json"),
        bundle_path,
        secret_path,
    )
    assert result.exit_code == 0, result.stdout
    decision = json.loads(result.stdout)
    assert decision == json.loads(result.stdout)  # deterministic
    assert decision["allowed"] is True
    assert decision["tool"] == "kcc_policy_write"
    assert len(decision["token"]) == 32
    assert (tmp_path / "src/kcc.py").read_text(encoding="utf-8") == "print('hi')\n"
    assert decision["outcome"]["operation"] == "create"


def test_cli_gate_exec_reads_stdin_and_reports_exit_code(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    lease = _make_run(tmp_path)
    terms = [PolicyRule("exec", "python3", "PUBLIC", PolicyDecision.ALLOWED)]
    bundle_path, secret_path = provision_gate_policy(
        tmp_path / "gate", rules=terms
    )
    result = _cli_run(
        tmp_path,
        "gate-exec",
        _exec_request(
            lease_id=lease.lease_id, command="python3", args=["--version"]
        ).model_dump(mode="json"),
        bundle_path,
        secret_path,
    )
    assert result.exit_code == 0, result.stdout
    decision = json.loads(result.stdout)
    assert decision["allowed"] is True
    assert decision["tool"] == "kcc_policy_exec"
    assert decision["outcome"]["command"] == "python3"
    assert decision["outcome"]["returncode"] == 0


def test_cli_gate_write_fails_closed_with_nonzero_exit(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    lease = _make_run(tmp_path)
    bundle_path, secret_path = provision_gate_policy(
        tmp_path / "gate", rules=[T5_WRITE_TERMS]
    )
    payload = _write_request(
        lease_id=lease.lease_id, path="forbidden.txt"
    ).model_dump(mode="json")
    result = _cli_run(tmp_path, "gate-write", payload, bundle_path, secret_path)
    assert result.exit_code == 1
    decision = json.loads(result.stdout)
    assert decision["allowed"] is False
    assert not (tmp_path / "forbidden.txt").exists()


def test_cli_gate_write_rejects_malformed_stdin(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    bundle_path, secret_path = provision_gate_policy(tmp_path / "gate")
    runner = CliRunner()
    result = runner.invoke(
        app,
        ["gate-write", "--bundle", str(bundle_path), "--secret-file", str(secret_path)],
        input="{not-json",
    )
    assert result.exit_code == 1
    decision = json.loads(result.stdout)
    assert decision["allowed"] is False
    assert "request" in (decision["reason"] or "").lower()


def test_cli_gate_write_uses_secret_file_env_when_option_absent(
    tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    lease = _make_run(tmp_path)
    bundle_path, secret_path = provision_gate_policy(
        tmp_path / "gate", rules=[T5_WRITE_TERMS]
    )
    monkeypatch.setenv("KCC_AUTOBUILD_POLICY_SECRET_FILE", str(secret_path))
    runner = CliRunner()
    result = runner.invoke(
        app,
        ["gate-write", "--bundle", str(bundle_path)],
        input=json.dumps(_write_request(lease_id=lease.lease_id).model_dump(mode="json")),
    )
    assert result.exit_code == 0, result.stdout
    assert json.loads(result.stdout)["allowed"] is True


def test_cli_gate_write_fails_closed_when_no_secret_is_configured(
    tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    lease = _make_run(tmp_path)
    bundle_path, _ = provision_gate_policy(tmp_path / "gate")
    monkeypatch.delenv("KCC_AUTOBUILD_POLICY_SECRET_FILE", raising=False)
    runner = CliRunner()
    result = runner.invoke(
        app,
        ["gate-write", "--bundle", str(bundle_path)],
        input=json.dumps(_write_request(lease_id=lease.lease_id).model_dump(mode="json")),
    )
    assert result.exit_code == 1
    assert json.loads(result.stdout)["allowed"] is False


def test_cli_gate_write_rejects_a_write_request_sent_to_gate_exec(
    tmp_path, monkeypatch
):
    # The command is internal and fixed: the wrong tool on the wire is
    # rejected, never reinterpreted.
    monkeypatch.chdir(tmp_path)
    lease = _make_run(tmp_path)
    bundle_path, secret_path = provision_gate_policy(
        tmp_path / "gate", rules=[T5_WRITE_TERMS]
    )
    payload = _exec_request(lease_id=lease.lease_id).model_dump(mode="json")
    result = _cli_run(tmp_path, "gate-write", payload, bundle_path, secret_path)
    assert result.exit_code == 1
    assert json.loads(result.stdout)["allowed"] is False


def test_gate_audit_path_is_confined_under_coordination(tmp_path):
    path = gate_audit_path(tmp_path, "RUN-001")
    assert path == (
        tmp_path / "coordination" / "autobuild" / "RUN-001" / "gate-audit.jsonl"
    )
    assert path.is_relative_to(tmp_path)
