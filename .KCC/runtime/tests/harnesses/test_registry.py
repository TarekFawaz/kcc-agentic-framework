"""Harness capability registry and selection (Plan 08, Task 2) -- tests.

Written first (strict TDD red phase) against the external behavior
contract of Task 2 of :file:`.superpowers/bootstrap/plans/
2026-08-27-08-harness-capability-deepseek-adapter.task-contracts.md`
(KCC x Superpowers Hybrid Framework)::

    HarnessRegistry.register/get/probe_all/select stable ties and
    capability-only scoring; requested harness must be detected/usable.
    Tests: beta parallel preferred; generic capability truth/degradation.

Binding semantics under test:

* ``register`` stores a concrete adapter under its ``harness_id``,
  rejects non-adapters, blank ids and duplicate ids (unless ``force``
  replaces the adapter and drops its stale probe).
* ``get`` returns the registered adapter; an unknown id raises
  ``KeyError`` (fail closed, never guessed).
* ``probe_all`` probes every registered adapter (cached between calls;
  ``refresh=True`` re-probes) and yields probe outcomes keyed by
  harness id in deterministic registration order; an adapter whose
  ``probe`` raises is reported as a failed, not-detected probe instead
  of breaking the whole registry (fail closed, no fake capability).
* ``select`` ranks DETECTED harnesses by a capability-only score
  (weights of the proven capability set times its confidence) -- never
  by harness name, version or registration order -- with stable ties
  broken by the lexicographically smallest harness id, so identical
  inputs always yield the same harness.  A parallel-capable beta
  harness must be preferred over a local-only generic one (capability
  truth, not CLI preference).
* ``select(requested=...)`` returns exactly the requested harness when
  it is detected and usable at/above the minimum strategy, and raises
  ``HarnessError`` when it is unknown, not detected, or below the
  minimum -- a requested harness is never silently replaced by
  another one.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from kcc_autobuild.bridge import ExecutionReport
from kcc_autobuild.harnesses import (
    ApprovalMode,
    ExecutionStrategy,
    HarnessAdapter,
    HarnessCapabilities,
    HarnessError,
    HarnessProbe,
    HarnessTask,
    MutationEnforcement,
)
from kcc_autobuild.harnesses.generic import GenericHarnessAdapter
from kcc_autobuild.harnesses.registry import HarnessRegistry, HarnessSelection


def _probe(
    harness_id: str,
    *,
    detected: bool = True,
    read: bool = False,
    write: bool = False,
    exec: bool = False,
    fresh_workers: bool = False,
    parallel_workers: bool = False,
    subagents: bool = False,
    approval_mode: ApprovalMode = ApprovalMode.UNKNOWN,
    mutation_enforcement: MutationEnforcement = MutationEnforcement.NONE,
    confidence: float = 1.0,
    error: str | None = None,
) -> HarnessProbe:
    """A probe outcome with explicit proven capability values."""
    return HarnessProbe(
        harness_id=harness_id,
        detected=detected,
        capabilities=HarnessCapabilities(
            read=read,
            write=write,
            exec=exec,
            fresh_workers=fresh_workers,
            parallel_workers=parallel_workers,
            subagents=subagents,
            approval_mode=approval_mode,
            mutation_enforcement=mutation_enforcement,
            confidence=confidence,
        ),
        probed_at=datetime(2026, 8, 29, 2, 0, 0, tzinfo=timezone.utc),
        evidence=[f"stub evidence for {harness_id}"] if detected else [],
        error=error,
    )


def _stub(
    harness_id: str,
    probe: HarnessProbe | None = None,
    *,
    fail: Exception | None = None,
) -> tuple[HarnessAdapter, list[int], dict[str, HarnessProbe | None]]:
    """A concrete stub adapter with a controllable probe result/call count."""
    calls: list[int] = [0]
    state: dict[str, HarnessProbe | None] = {"probe": probe}
    _id = harness_id

    class StubAdapter(HarnessAdapter):
        harness_id: str = _id

        def probe(self) -> HarnessProbe:
            calls[0] += 1
            if fail is not None:
                raise fail
            assert state["probe"] is not None
            return state["probe"]

        def execute(self, task: HarnessTask) -> ExecutionReport:  # pragma: no cover
            raise HarnessError(f"stub {harness_id} never executes tasks")

    return StubAdapter(), calls, state


class TestRegister:
    def test_register_and_get_round_trip(self) -> None:
        adapter, _, _ = _stub("alpha", _probe("alpha", read=True))
        registry = HarnessRegistry()
        registry.register(adapter)
        assert registry.get("alpha") is adapter

    def test_register_rejects_non_adapter(self) -> None:
        registry = HarnessRegistry()
        with pytest.raises(TypeError, match="HarnessAdapter"):
            registry.register(object())  # type: ignore[arg-type]

    def test_register_rejects_blank_harness_id(self) -> None:
        blank, _, _ = _stub("  ", _probe("alpha"))
        registry = HarnessRegistry()
        with pytest.raises(HarnessError, match="harness_id"):
            registry.register(blank)

    def test_register_rejects_duplicate_id_without_force(self) -> None:
        registry = HarnessRegistry()
        registry.register(_stub("alpha", _probe("alpha"))[0])
        with pytest.raises(HarnessError, match="already registered"):
            registry.register(_stub("alpha", _probe("alpha"))[0])

    def test_register_force_replaces_and_drops_stale_probe(self) -> None:
        registry = HarnessRegistry()
        registry.register(_stub("alpha", _probe("alpha", detected=True, read=True))[0])
        assert registry.probe_all()["alpha"].detected
        # Replace with an adapter whose probe outcome is NOT detected: the
        # stale cached probe must never survive the replacement.
        registry.register(
            _stub("alpha", _probe("alpha", detected=False, error="gone"))[0],
            force=True,
        )
        probe = registry.probe_all()["alpha"]
        assert probe.detected is False
        assert probe.error == "gone"


class TestGet:
    def test_get_unknown_harness_raises(self) -> None:
        registry = HarnessRegistry()
        with pytest.raises(KeyError, match="alpha"):
            registry.get("alpha")


class TestProbeAll:
    def test_probe_all_reports_every_registered_harness_in_registration_order(
        self,
    ) -> None:
        alpha, _, _ = _stub("alpha", _probe("alpha", detected=True, read=True))
        beta, _, _ = _stub("beta", _probe("beta", detected=False, error="nope"))
        registry = HarnessRegistry()
        registry.register(alpha)
        registry.register(beta)
        probes = registry.probe_all()
        assert list(probes) == ["alpha", "beta"]
        assert probes["alpha"].detected is True
        assert probes["beta"].detected is False
        assert probes["beta"].error == "nope"

    def test_probe_all_caches_until_refresh(self) -> None:
        adapter, calls, _ = _stub("alpha", _probe("alpha", detected=True, read=True))
        registry = HarnessRegistry()
        registry.register(adapter)
        registry.probe_all()
        registry.probe_all()
        assert calls[0] == 1  # second call served from cache
        registry.probe_all(refresh=True)
        assert calls[0] == 2  # refresh re-probes

    def test_raising_adapter_fails_closed_and_does_not_break_the_registry(self) -> None:
        broken, _, _ = _stub(
            "broken", fail=RuntimeError("probe exploded")
        )  # type: ignore[arg-type]
        healthy, _, _ = _stub("healthy", _probe("healthy", detected=True, read=True))
        registry = HarnessRegistry()
        registry.register(broken)
        registry.register(healthy)
        probes = registry.probe_all()
        assert probes["broken"].detected is False
        assert "probe exploded" in (probes["broken"].error or "")
        assert probes["healthy"].detected is True


class TestSelect:
    def test_beta_parallel_preferred_over_generic(self, tmp_path) -> None:
        """A parallel-proven beta harness beats the local-only generic one."""
        beta, _, _ = _stub(
            "beta",
            _probe(
                "beta",
                detected=True,
                read=True,
                write=True,
                exec=True,
                fresh_workers=True,
                parallel_workers=True,
                confidence=1.0,
            ),
        )
        registry = HarnessRegistry()
        registry.register(beta)
        registry.register(
            GenericHarnessAdapter(workspace=tmp_path, shell="sh")
        )
        selection = registry.select()
        assert selection.harness_id == "beta"
        assert selection.strategy is ExecutionStrategy.PARALLEL_WORKERS
        assert selection.score == pytest.approx(8.0)  # 1+1+1 + 2 (fresh) + 3 (parallel)

    def test_score_is_capability_only_not_cli_name(self) -> None:
        """The same capabilities score identically whatever the id is."""
        local_a, _, _ = _stub("codex", _probe("codex", read=True, write=True, exec=True))
        local_b, _, _ = _stub("dsh", _probe("dsh", read=True, write=True, exec=True))
        registry = HarnessRegistry()
        registry.register(local_a)
        registry.register(local_b)
        selection = registry.select()
        # Capability-only: both are local-only, so the stable tie-break picks
        # the lexicographically smallest id -- never a hardcoded CLI favorite.
        assert selection.harness_id == "codex"
        assert selection.score == pytest.approx(3.0)

    def test_stable_ties_are_independent_of_registration_order(self) -> None:
        zeta, _, _ = _stub(
            "zeta",
            _probe(
                "zeta",
                read=True,
                write=True,
                exec=True,
                parallel_workers=True,
            ),
        )
        alpha, _, _ = _stub(
            "alpha",
            _probe(
                "alpha",
                read=True,
                write=True,
                exec=True,
                parallel_workers=True,
            ),
        )
        registry = HarnessRegistry()
        registry.register(zeta)
        registry.register(alpha)
        assert registry.select().harness_id == "alpha"
        # Identical capability sets in the opposite registration order yield
        # the identical (lexicographic) choice -- ties are stable.
        registry2 = HarnessRegistry()
        registry2.register(alpha)
        registry2.register(zeta)
        assert registry2.select().harness_id == "alpha"

    def test_undetected_harnesses_are_never_candidates(self) -> None:
        ghost, _, _ = _stub(
            "ghost",
            _probe(
                "ghost",
                detected=False,
                read=True,
                write=True,
                exec=True,
                parallel_workers=True,
                error="not detected",
            ),
        )
        registry = HarnessRegistry()
        registry.register(ghost)
        with pytest.raises(HarnessError, match="no detected harness"):
            registry.select()

    def test_select_empty_registry_raises(self) -> None:
        with pytest.raises(HarnessError, match="no detected harness"):
            HarnessRegistry().select()

    def test_min_strategy_filters_candidates(self) -> None:
        generic, _, _ = _stub("generic", _probe("generic", read=True, write=True, exec=True))
        beta, _, _ = _stub(
            "beta",
            _probe(
                "beta",
                read=True,
                write=True,
                exec=True,
                fresh_workers=True,
                parallel_workers=True,
            ),
        )
        registry = HarnessRegistry()
        registry.register(generic)
        registry.register(beta)
        assert (
            registry.select(min_strategy=ExecutionStrategy.PARALLEL_WORKERS).harness_id
            == "beta"
        )
        with pytest.raises(HarnessError, match="minimum strategy"):
            registry.select(min_strategy=ExecutionStrategy.FULL_AUTOPILOT)

    def test_requested_harness_is_selected_exactly(self) -> None:
        generic, _, _ = _stub("generic", _probe("generic", read=True, write=True, exec=True))
        beta, _, _ = _stub(
            "beta",
            _probe(
                "beta",
                read=True,
                write=True,
                exec=True,
                fresh_workers=True,
                parallel_workers=True,
            ),
        )
        registry = HarnessRegistry()
        registry.register(generic)
        registry.register(beta)
        selection = registry.select(requested="generic")
        assert selection.harness_id == "generic"
        assert selection.strategy is ExecutionStrategy.LOCAL

    def test_requested_unknown_harness_raises(self) -> None:
        registry = HarnessRegistry()
        with pytest.raises(HarnessError, match="not registered"):
            registry.select(requested="nope")

    def test_requested_undetected_harness_raises(self) -> None:
        ghost, _, _ = _stub(
            "ghost",
            _probe("ghost", detected=False, read=True, error="probe failed"),
        )
        registry = HarnessRegistry()
        registry.register(ghost)
        with pytest.raises(HarnessError, match="not detected"):
            registry.select(requested="ghost")

    def test_requested_harness_below_minimum_strategy_raises(self) -> None:
        generic, _, _ = _stub("generic", _probe("generic", read=True, write=True, exec=True))
        registry = HarnessRegistry()
        registry.register(generic)
        with pytest.raises(HarnessError, match="minimum strategy"):
            registry.select(
                requested="generic",
                min_strategy=ExecutionStrategy.SERIAL_WORKER,
            )

    def test_select_refresh_reprobes_before_deciding(self) -> None:
        first = _probe("alpha", detected=True, read=True)
        second = _probe("alpha", detected=False, error="vanished")
        adapter, calls, state = _stub("alpha", first)
        registry = HarnessRegistry()
        registry.register(adapter)
        assert registry.select().harness_id == "alpha"
        state["probe"] = second
        with pytest.raises(HarnessError, match="no detected harness"):
            registry.select(refresh=True)
        assert calls[0] == 2  # first select, then refresh re-probe


class TestHarnessSelection:
    def test_selection_exposes_probe_strategy_and_score(self) -> None:
        probe = _probe(
            "alpha",
            read=True,
            write=True,
            exec=True,
            fresh_workers=True,
            parallel_workers=True,
        )
        selection = HarnessSelection(harness_id="alpha", probe=probe, score=8.0)
        assert selection.harness_id == "alpha"
        assert selection.probe is probe
        assert selection.detected is True
        assert selection.capabilities is probe.capabilities
        assert selection.strategy is ExecutionStrategy.PARALLEL_WORKERS
        assert selection.score == pytest.approx(8.0)

    def test_selection_is_immutable(self) -> None:
        probe = _probe("alpha", read=True)
        selection = HarnessSelection(harness_id="alpha", probe=probe, score=1.0)
        with pytest.raises(AttributeError):
            selection.harness_id = "beta"  # type: ignore[misc]
