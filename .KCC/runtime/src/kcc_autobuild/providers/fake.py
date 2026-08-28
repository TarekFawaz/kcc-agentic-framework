"""Configurable fake provider validator for tests and local runs.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_readiness.py`
(see the KCC x Superpowers Hybrid Framework Plan 02, Task 2).

This is a test double, not a real provider integration: every probe
returns a canned :class:`~kcc_autobuild.providers.base.ProbeResult`
configured at construction.  Unconfigured probes default to
``unknown`` so the fail-closed readiness semantics are exercised
instead of silently passing.
"""

from __future__ import annotations

from kcc_autobuild.providers.base import ProbeResult, ProviderValidator

_UNKNOWN = ProbeResult(status="unknown")


class FakeProvider:
    """In-memory :class:`ProviderValidator` with canned probe outcomes.

    Args:
        name: human-readable provider identifier (informational).
        identity/permissions/quota/smoke_probe: canned probe results;
            each defaults to ``ProbeResult(status="unknown")``.
    """

    def __init__(
        self,
        *,
        name: str = "fake",
        identity: ProbeResult | None = None,
        permissions: ProbeResult | None = None,
        quota: ProbeResult | None = None,
        smoke_probe: ProbeResult | None = None,
    ) -> None:
        self.name = name
        self._identity = _UNKNOWN if identity is None else identity
        self._permissions = _UNKNOWN if permissions is None else permissions
        self._quota = _UNKNOWN if quota is None else quota
        self._smoke_probe = _UNKNOWN if smoke_probe is None else smoke_probe

    def identity(self) -> ProbeResult:
        return self._identity

    def permissions(self) -> ProbeResult:
        return self._permissions

    def quota(self) -> ProbeResult:
        return self._quota

    def smoke_probe(self) -> ProbeResult:
        return self._smoke_probe
