"""Capability harness registry and selection (Plan 08, Task 2).

The registry is the adapter registry of the harness-neutral core: it
holds the concrete :class:`~kcc_autobuild.harnesses.base.HarnessAdapter`
instances, caches their :class:`HarnessProbe` outcomes and decides which
harness a dispatch runs on.  Behavioral contract owned by
:file:`.KCC/runtime/tests/harnesses/test_registry.py` (Task 2:
"Capability registry + generic compatibility mode", in
``.superpowers/bootstrap/plans/2026-08-27-08-``
``harness-capability-deepseek-adapter.task-contracts.md``).

Decisions are **capability-only**:

* :func:`capability_score` scores a capability set purely from its
  proven capabilities and confidence -- never from a harness name,
  version or registration order.
* :func:`select_harness_by_capability` and
  :meth:`HarnessRegistry.select` rank only harnesses whose probe
  *detected* them as usable; ties are stable (highest score, then the
  lexicographically smallest ``harness_id``), so identical probe
  outcomes always yield the identical harness.
* A ``requested`` harness is returned exactly when it is detected and
  usable at/above the minimum strategy; an unknown, undetected or
  below-minimum requested harness raises :class:`HarnessError` instead
  of silently falling back to another harness (fail closed).

A probe failure never fakes a capability: an adapter whose ``probe``
raises is reported as a not-detected probe with the error recorded
(:meth:`HarnessRegistry.probe_all` never propagates one adapter's
breakage over the other adapters' outcomes).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Mapping

from kcc_autobuild.harnesses.base import HarnessAdapter
from kcc_autobuild.harnesses.models import (
    ApprovalMode,
    ExecutionStrategy,
    HarnessCapabilities,
    HarnessError,
    HarnessProbe,
    MutationEnforcement,
)

_STRATEGY_RANK: dict[ExecutionStrategy, int] = {
    ExecutionStrategy.LOCAL: 0,
    ExecutionStrategy.SERIAL_WORKER: 1,
    ExecutionStrategy.PARALLEL_WORKERS: 2,
    ExecutionStrategy.FULL_AUTOPILOT: 3,
}


def capability_score(capabilities: HarnessCapabilities) -> float:
    """Capability-only score of one proven capability set.

    Each proven capability contributes its weight (read/write/exec/
    subagents 1, fresh-workers 2, parallel-workers 3, KCC policy gate 2,
    passive approval 1); the sum is scaled by the probe confidence.  No
    name, version or registration-order information enters the score.
    """
    score = 0.0
    if capabilities.read:
        score += 1.0
    if capabilities.write:
        score += 1.0
    if capabilities.exec:
        score += 1.0
    if capabilities.subagents:
        score += 1.0
    if capabilities.fresh_workers:
        score += 2.0
    if capabilities.parallel_workers:
        score += 3.0
    if capabilities.mutation_enforcement is MutationEnforcement.KCC_POLICY_GATE:
        score += 2.0
    if capabilities.approval_mode in (ApprovalMode.NONE, ApprovalMode.NEVER):
        score += 1.0
    return score * capabilities.confidence


@dataclass(frozen=True)
class HarnessSelection:
    """One capability-made harness choice for a dispatch.

    ``harness_id`` names the selected adapter, ``probe`` is the probe
    outcome that justified it and ``score`` is the capability-only score
    it was ranked with.  ``strategy`` is the proven execution strategy of
    the selected harness (``probe.capabilities.best_strategy()``) --
    dispatch decisions consume this capability/strategy, never a bare
    CLI name.
    """

    harness_id: str
    probe: HarnessProbe
    score: float

    @property
    def capabilities(self) -> HarnessCapabilities:
        """The proven capability set that justified this selection."""
        return self.probe.capabilities

    @property
    def strategy(self) -> ExecutionStrategy:
        """The proven execution strategy of the selected harness."""
        return self.probe.capabilities.best_strategy()

    @property
    def detected(self) -> bool:
        """Whether the selected harness was detected as usable."""
        return self.probe.detected


def select_harness_by_capability(
    probes: Mapping[str, HarnessProbe],
    *,
    requested: str | None = None,
    min_strategy: ExecutionStrategy = ExecutionStrategy.LOCAL,
) -> HarnessSelection:
    """Pure capability-only harness selection over probe outcomes.

    ``probes`` maps harness id to its (already recorded) probe outcome;
    only probe outcomes with ``detected`` true are candidates, and only
    those whose proven strategy is at/above ``min_strategy``.  The
    winner is the highest capability score; ties are stable: the
    lexicographically smallest harness id wins, independent of mapping
    order.

    With ``requested`` set, exactly that harness is returned when
    detected and usable at/above the minimum strategy; otherwise
    :class:`HarnessError` is raised -- a requested harness is never
    silently replaced by another one (fail closed).
    """
    if requested is not None:
        if requested not in probes:
            raise HarnessError(f"requested harness {requested!r} is not registered")
        probe = probes[requested]
        _require_usable(requested, probe, min_strategy)
        return HarnessSelection(
            harness_id=requested,
            probe=probe,
            score=capability_score(probe.capabilities),
        )

    candidates: list[HarnessSelection] = []
    for harness_id in sorted(probes):
        probe = probes[harness_id]
        if not probe.detected:
            continue  # an undetected probe claims nothing; never a candidate
        if _below(probe.capabilities, min_strategy):
            continue
        candidates.append(
            HarnessSelection(
                harness_id=harness_id,
                probe=probe,
                score=capability_score(probe.capabilities),
            )
        )
    if not candidates:
        raise HarnessError(
            "no detected harness supports the required minimum strategy "
            f"'{min_strategy.value}'"
        )
    # Highest score first; stable ties broken by harness id ascending.
    candidates.sort(key=lambda selection: (-selection.score, selection.harness_id))
    return candidates[0]


def _below(capabilities: HarnessCapabilities, min_strategy: ExecutionStrategy) -> bool:
    return _STRATEGY_RANK[capabilities.best_strategy()] < _STRATEGY_RANK[min_strategy]


def _require_usable(
    harness_id: str,
    probe: HarnessProbe,
    min_strategy: ExecutionStrategy,
) -> None:
    """A requested harness must be detected AND usable (fail closed)."""
    if not probe.detected:
        raise HarnessError(
            f"requested harness {harness_id!r} was not detected (not usable)"
        )
    if _below(probe.capabilities, min_strategy):
        raise HarnessError(
            f"requested harness {harness_id!r} supports "
            f"'{probe.capabilities.best_strategy().value}', below the "
            f"required minimum strategy '{min_strategy.value}'"
        )


class HarnessRegistry:
    """Registry of harness adapters with cached probe outcomes.

    ``register`` stores a concrete adapter under its ``harness_id``;
    ``get`` returns the registered adapter; ``probe``/``probe_all`` run
    the adapter probes (cached until ``refresh``) and ``select`` ranks
    the detected harnesses by capability only (see
    :func:`select_harness_by_capability`).
    """

    def __init__(self) -> None:
        self._adapters: dict[str, HarnessAdapter] = {}
        self._probes: dict[str, HarnessProbe] = {}

    def register(self, adapter: HarnessAdapter, *, force: bool = False) -> None:
        """Register a concrete adapter under its ``harness_id``.

        A non-adapter raises :class:`TypeError`; a blank ``harness_id``
        or an already-registered id raises :class:`HarnessError`.
        ``force=True`` replaces the adapter and drops its stale cached
        probe (the next probe observes the replacement).
        """
        if not isinstance(adapter, HarnessAdapter):
            raise TypeError(
                f"adapter must be a HarnessAdapter, got {type(adapter).__name__}"
            )
        harness_id = adapter.harness_id
        if not isinstance(harness_id, str) or not harness_id.strip():
            raise HarnessError("adapter harness_id must be a non-blank string")
        if harness_id in self._adapters and not force:
            raise HarnessError(f"harness {harness_id!r} is already registered")
        self._adapters[harness_id] = adapter
        if force:
            self._probes.pop(harness_id, None)

    def get(self, harness_id: str) -> HarnessAdapter:
        """The registered adapter for ``harness_id`` (``KeyError`` unknown)."""
        if harness_id not in self._adapters:
            raise KeyError(f"no harness {harness_id!r} is registered")
        return self._adapters[harness_id]

    def probe(self, harness_id: str, *, refresh: bool = False) -> HarnessProbe:
        """The cached probe outcome of one harness (probe on cache miss)."""
        adapter = self.get(harness_id)
        if refresh or harness_id not in self._probes:
            self._probes[harness_id] = self._safe_probe(adapter)
        return self._probes[harness_id]

    def probe_all(self, *, refresh: bool = False) -> dict[str, HarnessProbe]:
        """Probe outcomes of every registered harness, by harness id.

        Outcomes are cached (``refresh=False`` re-uses them; missing
        outcomes are probed now) and returned in deterministic
        registration order.  An adapter whose ``probe`` raises is
        recorded as a not-detected probe instead of propagating: one
        broken adapter never fakes or hides the other outcomes.
        """
        for harness_id in self._adapters:
            self.probe(harness_id, refresh=refresh)
        return dict(self._probes)

    def select(
        self,
        *,
        requested: str | None = None,
        min_strategy: ExecutionStrategy = ExecutionStrategy.LOCAL,
        refresh: bool = False,
    ) -> HarnessSelection:
        """Select the harness for a dispatch by capability only.

        Probes (or reuses the cached outcomes when ``refresh`` is false),
        then ranks the detected harnesses with
        :func:`select_harness_by_capability`.  A ``requested`` harness is
        returned only when it was detected as usable (fail closed).
        """
        probes = self.probe_all(refresh=refresh)
        return select_harness_by_capability(
            probes,
            requested=requested,
            min_strategy=min_strategy,
        )

    @staticmethod
    def _safe_probe(adapter: HarnessAdapter) -> HarnessProbe:
        """Record an adapter probe outcome, converting exceptions to failure."""
        try:
            return adapter.probe()
        except Exception as exc:  # noqa: BLE001 -- fail closed, never fake
            return HarnessProbe(
                harness_id=adapter.harness_id,
                detected=False,
                capabilities=HarnessCapabilities.unknown(),
                probed_at=datetime.now(timezone.utc),
                error=f"probe raised {type(exc).__name__}: {exc}",
            )
