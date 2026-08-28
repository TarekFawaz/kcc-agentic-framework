"""Typer CLI over the autobuild runtime.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_cli.py`
(see the KCC x Superpowers Hybrid Framework Plan 01, Task 4, and
Plan 02, Task 5 for the real ``validate-model`` schema validation).

Output is deterministic: commands that print a model use
``json.dumps(model.model_dump(mode='json'), sort_keys=True)`` so the
machine-readable contract of the CLI output is stable. ``validate-model``
is real YAML/schema validation (Plan-02 ruling R5): model kinds map to
the actual Pydantic models and invalid input exits non-zero — failures
are never swallowed into exit 0.  The kind map includes
``execution-report`` (Plan 03, Task 4): the bounded execution skill's
final gate is ``kcc-autobuild validate-model execution-report <path>``,
so the bridge's terminal report model must be a real schema kind.

Plan 08, Task 4 adds the ``harness`` group: ``harness probe dsh``
features-probes the DeepSeek Harness adapter and ``harness doctor dsh``
(preflight, or ``--live`` proof) validates the effective hardened
profile/guard of the disposable ``kcc-autobuild`` profile before
``approval_mode=NEVER`` + ``mutation_enforcement=KCC_POLICY_GATE`` can
ever be granted.

Plan 08, Task 7 adds ``harness smoke dsh`` (the real smoke/evidence
gate): ``--runs`` disposable fresh workers under a disposable hardened
profile/workspace must prove status + authorized governed mutation +
denied raw write/bash + zero prompts/secrets, every worker must emit a
valid ExecutionReport, the durable artifacts are secret-scanned and
``coordination/autobuild/evaluations/dsh-smoke.json`` is written -- exit
0 only when the evaluation passed; the smoke never promotes a rollout
(Plan 07 R3 consumes the fresh evidence).

Plan 08, Task 5 adds the internal policy gate entry points
``gate-write`` / ``gate-exec``: the DSH Cordis wrappers
(``kcc_policy_write`` / ``kcc_policy_exec``) call them with the
untrusted operation request on stdin; they reload the durable run,
reject stale leases, verify the signed policy bundle and only then run
the policy-bound executor.  They are internal wiring -- never
user-facing commands.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import typer
import yaml
from pydantic import ValidationError

from kcc_autobuild.bridge import ExecutionReport
from kcc_autobuild.contract import BuildContract
from kcc_autobuild.decision_log import DecisionLog
from kcc_autobuild.models import RUN_ID_PATTERN, LifecycleState, RunRecord
from kcc_autobuild.prototype import Prototype
from kcc_autobuild.readiness import ReadinessPack
from kcc_autobuild.store import RunStore
from kcc_autobuild.trace import TraceGraph

app = typer.Typer(no_args_is_help=True)

harness_app = typer.Typer(
    no_args_is_help=True,
    help="Probe and doctor a fitted harness adapter (Plan 08).",
)
app.add_typer(harness_app, name="harness")

MODEL_KINDS: dict[str, type] = {
    "trace": TraceGraph,
    "readiness": ReadinessPack,
    "contract": BuildContract,
    "decision-log": DecisionLog,
    "prototype": Prototype,
    "execution-report": ExecutionReport,
}
"""Map the ``validate-model`` kind strings to the real Pydantic models.

The six kinds are the approved autobuild artifact kinds (Plan-02 ruling
R5, plus the Plan 03 execution bridge): trace matrix, readiness evidence
pack, build contract, decision log, clickable prototype manifest and the
worker's terminal Execution Report.  ``execution-report`` is the final
gate of the bounded task-execution skill: a report that does not
validate against :class:`kcc_autobuild.bridge.ExecutionReport` is
malformed and is rejected before any chain-of-custody check.
"""


def db_for(repo_root: Path, run_id: str) -> Path:
    """Return the ``run.db`` path for a run under a repository root."""
    return repo_root / "coordination" / "autobuild" / run_id / "run.db"


def validate_run_id(run_id: str) -> None:
    """Reject run ids that do not match the canonical identity pattern.

    Runs before any RunStore/db_for use so an invalid identity can never
    create a coordination directory or database.
    """
    if re.fullmatch(RUN_ID_PATTERN, run_id) is None:
        raise typer.BadParameter(
            f"invalid run_id {run_id!r}; must match {RUN_ID_PATTERN}"
        )


def require_existing_run_db(db_path: Path, run_id: str) -> None:
    """Fail if the run database does not exist (never create-on-read)."""
    if not db_path.exists():
        typer.echo(
            f"error: run {run_id!r} not found (no database at {db_path})",
            err=True,
        )
        raise typer.Exit(code=1)


def deterministic_json(model: RunRecord) -> str:
    """Serialize a model deterministically (sorted keys, JSON-safe values)."""
    return json.dumps(model.model_dump(mode='json'), sort_keys=True)


@app.command("init-run")
def init_run(
    run_id: str,
    title: str,
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds coordination/"
    ),
) -> None:
    """Create an autobuild run in INTAKE and print its record as JSON."""
    validate_run_id(run_id)
    store = RunStore(db_for(repo_root, run_id))
    try:
        record = RunRecord(
            run_id=run_id,
            title=title,
            created_at=datetime.now(timezone.utc),
        )
        store.create_run(record)
        typer.echo(deterministic_json(record))
    finally:
        store.close()


@app.command("show-run")
def show_run(
    run_id: str,
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds coordination/"
    ),
) -> None:
    """Load an existing run and print its record as deterministic JSON."""
    validate_run_id(run_id)
    run_db = db_for(repo_root, run_id)
    require_existing_run_db(run_db, run_id)
    store = RunStore(run_db)
    try:
        typer.echo(deterministic_json(store.load_run(run_id)))
    finally:
        store.close()


@app.command("transition")
def transition(
    run_id: str,
    target: LifecycleState,
    expected: LifecycleState = typer.Option(
        ..., help="Expected current state of the run"
    ),
    reason: str = typer.Option(
        "manual-controller-transition",
        help="Reason recorded with the transition",
    ),
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds coordination/"
    ),
) -> None:
    """Transition a run to target; non-zero exit if the transition is invalid."""
    validate_run_id(run_id)
    run_db = db_for(repo_root, run_id)
    require_existing_run_db(run_db, run_id)
    store = RunStore(run_db)
    try:
        store.transition(run_id, expected=expected, target=target, reason=reason)
        typer.echo(deterministic_json(store.load_run(run_id)))
    finally:
        store.close()


@app.command("validate-model")
def validate_model(kind: str, path: Path) -> None:
    """Validate a YAML artifact against the real autobuild model schema.

    Kinds: trace, readiness, contract, decision-log, prototype,
    execution-report.  Exits 0 with deterministic JSON when the artifact
    is valid; exits non-zero with a deterministic JSON error document on
    stderr for an unknown kind, a missing file, malformed YAML or a
    model schema violation (Plan-02 ruling R5 — this is real validation,
    not an existence probe, so LOCK validation is meaningful, and the
    ``execution-report`` kind backs the bounded execution skill's final
    report gate).
    """
    model_cls = MODEL_KINDS.get(kind)
    if model_cls is None:
        _validate_model_error(
            kind, path, [f"unknown model kind '{kind}'"]
        )
    if not path.exists():
        _validate_model_error(kind, path, ["file not found"])
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except (yaml.YAMLError, OSError) as exc:
        _validate_model_error(kind, path, [str(exc)])
    try:
        model_cls.model_validate(data)
    except ValidationError as exc:
        errors = sorted(str(error["msg"]) for error in exc.errors())
        _validate_model_error(kind, path, errors)
    typer.echo(
        json.dumps(
            {"kind": kind, "path": str(path), "valid": True},
            sort_keys=True,
        )
    )


def _validate_model_error(kind: str, path: Path, errors: list[str]) -> None:
    """Report an invalid artifact deterministically and exit non-zero."""
    typer.echo(
        json.dumps(
            {
                "kind": kind,
                "path": str(path),
                "valid": False,
                "errors": list(errors),
            },
            sort_keys=True,
        ),
        err=True,
    )
    raise typer.Exit(code=1)


# ---------------------------------------------------------------------------
# Plan 08 -- harness probe/doctor CLI (adapter-specific capability levels).
# ---------------------------------------------------------------------------


def _require_dsh(harness: str) -> None:
    """Only the dsh adapter is fitted by this CLI so far (fail closed)."""
    if harness != "dsh":
        typer.echo(
            json.dumps(
                {"harness": harness, "error": f"no adapter fitted for harness {harness!r}"},
                sort_keys=True,
            ),
            err=True,
        )
        raise typer.Exit(code=1)


@harness_app.command("probe")
def harness_probe(
    harness: str,
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds the dsh workspace"
    ),
    dsh_bin: str = typer.Option(
        "dsh", help="The dsh CLI command/executable to feature-probe"
    ),
    dsh_home: str | None = typer.Option(
        None, help="DSH home directory (default: $DSH_HOME or ~/.dsh)"
    ),
    profile: str = typer.Option(
        "headless", help="The installed headless profile to probe"
    ),
    timeout: float = typer.Option(
        30.0, help="Time budget (seconds) of each feature-probe subprocess"
    ),
) -> None:
    """Feature-probe a harness adapter and print its capability report.

    The probe is feature-based (never an exact-version gate) and reports
    ONLY proven capabilities: native ``AGENTS.md`` + generated
    ``.dsh/skills`` packages, dsh CLI boot, installed headless profile
    (fresh/parallel workers) and the passed live doctor proof
    (``approval_mode=NEVER`` + ``kcc-policy-gate``) when fed one.
    """
    _require_dsh(harness)
    from kcc_autobuild.harnesses.dsh import DshHarnessAdapter

    adapter = DshHarnessAdapter(
        dsh_bin=dsh_bin,
        workspace=repo_root,
        dsh_home=Path(dsh_home) if dsh_home else None,
        profile=profile,
        timeout_seconds=timeout,
    )
    probe = adapter.probe()
    typer.echo(
        json.dumps(probe.model_dump(mode="json"), sort_keys=True)
    )


@harness_app.command("doctor")
def harness_doctor(
    harness: str,
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds the dsh workspace"
    ),
    dsh_bin: str = typer.Option(
        "dsh", help="The dsh CLI command/executable to run"
    ),
    dsh_home: str | None = typer.Option(
        None, help="DSH home directory (default: $DSH_HOME or ~/.dsh)"
    ),
    profile: str = typer.Option(
        "kcc-autobuild", help="Name of the disposable profile the doctor boots"
    ),
    template: str = typer.Option(
        "headless", help="Installed profile the disposable profile is templated from"
    ),
    live: bool = typer.Option(
        False,
        "--live",
        help="Run the live doctor (disposable worker invokes kcc_harness_status)",
    ),
    timeout: float = typer.Option(
        600.0, help="Time budget (seconds) of the live worker probe"
    ),
) -> None:
    """Doctor the dsh harness against the effective profile/guard.

    Without ``--live`` this is a read-only preflight of the disposable
    ``kcc-autobuild`` profile (installed template, CLI boot, profile
    boot) -- its outcome is never a proof.  With ``--live`` the doctor
    boots the disposable profile, invokes ``kcc_harness_status`` exactly
    once and accepts exactly one ``KCC_DSH_STATUS:`` JSON line proving
    sandbox ``workspace-write``, approval ``never`` and the
    ``kcc-policy-gate`` guard; any extra/missing/prompt/error fails.
    """
    _require_dsh(harness)
    from kcc_autobuild.harnesses.dsh import dsh_doctor

    outcome = dsh_doctor(
        live=live,
        dsh_bin=dsh_bin,
        workspace=repo_root,
        dsh_home=Path(dsh_home) if dsh_home else None,
        profile=profile,
        template=template,
        timeout_seconds=timeout,
    )
    typer.echo(
        json.dumps(outcome.model_dump(mode="json"), sort_keys=True)
    )
    if not outcome.passed:
        raise typer.Exit(code=1)


@harness_app.command("smoke")
def harness_smoke(
    harness: str,
    fixture: Path | None = typer.Option(
        None,
        help="The dsh-smoke fixture directory (AGENTS.md + input/); "
        "default: the bundled repo fixture",
    ),
    runs: int = typer.Option(
        3, min=1, help="Number of disposable fresh-worker smoke runs"
    ),
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds the durable evaluation"
    ),
    dsh_bin: str = typer.Option(
        "dsh", help="The dsh CLI command/executable to run"
    ),
    dsh_home: str | None = typer.Option(
        None, help="DSH home directory (default: $DSH_HOME or ~/.dsh)"
    ),
    profile: str = typer.Option(
        "kcc-autobuild", help="Name of the disposable hardened profile the smoke boots"
    ),
    template: str = typer.Option(
        "kcc-autobuild",
        help="Installed hardened profile the disposable one is templated from",
    ),
    timeout: float = typer.Option(
        900.0, help="Time budget (seconds) of one disposable worker run"
    ),
    boot_timeout: float = typer.Option(
        120.0, help="Time budget (seconds) of the CLI feature probe"
    ),
    temp_root: Path | None = typer.Option(
        None, help="Temporary root for the disposable profile/workspace (tests)"
    ),
) -> None:
    """Run the real dsh smoke/evidence gate and write the evaluation.

    Each of the ``runs`` dispatches one fresh worker in a DISPOSABLE
    hardened profile (temporary DSH_HOME, templated from the installed
    hardened profile, disposable gate wiring + bounded allow policy) and
    a DISPOSABLE workspace (private fixture copy): the worker must
    read/code/test with no raw mutation, mutate ONLY through the KCC
    wrappers, get its deliberate built-in write/bash attempt
    guard-denied without a prompt, prove the status with exactly one
    ``KCC_DSH_STATUS:`` line and emit a valid identity-bound
    ExecutionReport.  The durable artifacts are secret-scanned and the
    evaluation ``coordination/autobuild/evaluations/dsh-smoke.json`` is
    written; the command exits 0 ONLY when the smoke passed.  It never
    promotes a rollout itself -- Plan 07 R3 consumes the fresh evidence.
    """
    _require_dsh(harness)
    from kcc_autobuild.harnesses.dsh import (
        SMOKE_FIXTURE_AGENTS,
        dsh_smoke,
        smoke_evidence_document,
        write_smoke_evaluation,
    )

    if fixture is None:
        fixture = (
            Path(__file__).resolve().parents[3]
            / "runtime"
            / "tests"
            / "harnesses"
            / "fixtures"
            / "dsh-smoke"
        )
    if fixture is None or not fixture.is_dir() or not (
        fixture / SMOKE_FIXTURE_AGENTS
    ).is_file():
        typer.echo(
            json.dumps(
                {
                    "fixture": str(fixture),
                    "error": "smoke fixture must be a directory containing "
                    f"{SMOKE_FIXTURE_AGENTS} and input/",
                },
                sort_keys=True,
            ),
            err=True,
        )
        raise typer.Exit(code=1)
    evidence = dsh_smoke(
        fixture=fixture,
        runs=runs,
        dsh_bin=dsh_bin,
        workspace=repo_root,
        dsh_home=Path(dsh_home) if dsh_home else None,
        profile=profile,
        template=template,
        timeout_seconds=timeout,
        boot_timeout_seconds=boot_timeout,
        temp_root=temp_root,
        repo_root=repo_root,
    )
    write_smoke_evaluation(repo_root, evidence)
    typer.echo(json.dumps(smoke_evidence_document(evidence), sort_keys=True))
    if not evidence.passed:
        raise typer.Exit(code=1)


# ---------------------------------------------------------------------------
# Plan 08, Task 5 -- internal policy gate (called by the DSH Cordis wrappers
# with the untrusted operation request on stdin; never a user-facing command).
# ---------------------------------------------------------------------------


def _gate_cli(
    tool: str,
    bundle: Path | None,
    secret_file: Path | None,
    timeout: float,
) -> None:
    """Run one internal ``gate-write`` / ``gate-exec`` request from stdin.

    The wrapper (trusted Cordis plugin) launches this process with cwd =
    the session workspace, so the request never carries a caller cwd and
    the process cwd IS the confinement anchor.  The request JSON plus
    run/task/lease identity arrives on stdin; no raw secret ever appears
    on the command line -- the signing secret is read from the owner-only
    file named by ``--secret-file`` or
    ``KCC_AUTOBUILD_POLICY_SECRET_FILE`` (fail closed when absent).
    """
    from kcc_autobuild.dsh_gate import (
        DshToolGate,
        GateDecision,
        GateRequest,
    )

    raw = sys.stdin.read()
    payload = None
    if raw.strip():
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            payload = None
            raw_error = f"unusable request: stdin is not valid JSON ({exc})"
        else:
            raw_error = ""
    else:
        raw_error = "unusable request: stdin is empty"

    def emit(decision: GateDecision) -> None:
        typer.echo(
            json.dumps(decision.model_dump(mode="json"), sort_keys=True)
        )

    if payload is None:
        decision = GateDecision(
            allowed=False,
            tool=tool,
            reason=(raw_error or "unusable request: stdin is not valid JSON"),
        )
        emit(decision)
        raise typer.Exit(code=1)
    if not isinstance(payload, dict):
        emit(
            GateDecision(
                allowed=False,
                tool=tool,
                reason="unusable request: stdin is not a JSON object",
            )
        )
        raise typer.Exit(code=1)
    gate = DshToolGate(
        repo_root=Path.cwd(),
        bundle_path=bundle,
        secret_file=secret_file,
        timeout_seconds=timeout,
    )
    try:
        # The command pins the tool: a request for the other wrapper is
        # rejected, never reinterpreted.
        request = GateRequest.model_validate({**payload, "tool": tool})
        decision = gate.handle(request)
    except Exception as exc:  # noqa: BLE001 -- the gate must fail closed
        decision = GateDecision(
            allowed=False,
            tool=tool,
            reason=f"invalid gate request: {type(exc).__name__}: {str(exc)[:400]}",
        )
    emit(decision)
    if not decision.allowed:
        raise typer.Exit(code=1)


@app.command("gate-write")
def gate_write(
    bundle: Path | None = typer.Option(
        None,
        "--bundle",
        help="Signed policy bundle the gate verifies (default: "
        ".KCC/adapters/dsh/gate/policy-bundle.json under the process cwd)",
    ),
    secret_file: Path | None = typer.Option(
        None,
        "--secret-file",
        help="Owner-only file holding the HMAC secret (default: "
        "$KCC_AUTOBUILD_POLICY_SECRET_FILE); never a raw secret argument",
    ),
    timeout: float = typer.Option(
        600.0, help="Time budget (seconds) of a governed subprocess"
    ),
) -> None:
    """Internal: govern one ``kcc_policy_write`` request from stdin."""
    _gate_cli("kcc_policy_write", bundle, secret_file, timeout)


@app.command("gate-exec")
def gate_exec(
    bundle: Path | None = typer.Option(
        None,
        "--bundle",
        help="Signed policy bundle the gate verifies (default: "
        ".KCC/adapters/dsh/gate/policy-bundle.json under the process cwd)",
    ),
    secret_file: Path | None = typer.Option(
        None,
        "--secret-file",
        help="Owner-only file holding the HMAC secret (default: "
        "$KCC_AUTOBUILD_POLICY_SECRET_FILE); never a raw secret argument",
    ),
    timeout: float = typer.Option(
        600.0, help="Time budget (seconds) of a governed subprocess"
    ),
) -> None:
    """Internal: govern one ``kcc_policy_exec`` request from stdin."""
    _gate_cli("kcc_policy_exec", bundle, secret_file, timeout)
