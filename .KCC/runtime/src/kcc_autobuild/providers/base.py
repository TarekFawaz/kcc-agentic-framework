"""Provider probe contract for the autobuild readiness evidence layer.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_readiness.py`
(see the KCC x Superpowers Hybrid Framework Plan 02, Task 2).

A provider validator performs four live probes against a provider:
``identity``, ``permissions``, ``quota`` and ``smoke_probe``.  Every
probe returns a typed :class:`ProbeResult`; the readiness layer turns
those results into timezone-aware evidence records via
:func:`kcc_autobuild.readiness.record_evidence`.
"""

from __future__ import annotations

from typing import Literal, Protocol

from pydantic import Field

from kcc_autobuild.models import StrictModel

EvidenceKind = Literal["identity", "permissions", "quota", "smoke_probe"]
"""Kinds of evidence probes a provider validator performs."""

EvidenceResult = Literal["pass", "fail", "unknown"]
"""Verdict of a single probe; fail-closed default is ``unknown``."""


class ProbeResult(StrictModel):
    """Structured outcome of a single provider probe.

    ``status`` is the probe verdict; the remaining fields record the
    facts the probe verified: the resolved identity principal, the
    resource ids proven reachable, the granted permission scopes, the
    execution ``mode`` (e.g. ``sandbox``/``live``), the observed quota
    and whether the credential belongs to a shared/human-identity-bound
    account.  ``detail`` holds free-form supporting text.
    """

    status: EvidenceResult
    detail: str = ""
    principal: str | None = None
    resource_ids: list[str] = Field(default_factory=list)
    scopes: list[str] = Field(default_factory=list)
    mode: str | None = None
    quota: str | None = None
    shared_account: bool = False


class ProviderValidator(Protocol):
    """Probe contract implemented by provider validators.

    Each method performs one live evidence probe against the provider
    the validator was configured for and returns a typed
    :class:`ProbeResult`.  Implementations are duck-typed: any object
    exposing all four methods satisfies the contract.
    """

    def identity(self) -> ProbeResult:
        """Prove the credential resolves to the expected identity."""
        ...

    def permissions(self) -> ProbeResult:
        """Prove the required permission scopes are granted."""
        ...

    def quota(self) -> ProbeResult:
        """Prove the provider quota/limit supports the planned workload."""
        ...

    def smoke_probe(self) -> ProbeResult:
        """Prove the smallest safe deployment/integration path works."""
        ...
