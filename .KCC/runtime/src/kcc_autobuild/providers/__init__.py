"""Provider validation contracts for autobuild readiness evidence."""

from __future__ import annotations

from kcc_autobuild.providers.base import (
    EvidenceKind,
    EvidenceResult,
    ProbeResult,
    ProviderValidator,
)
from kcc_autobuild.providers.fake import FakeProvider

__all__ = [
    "EvidenceKind",
    "EvidenceResult",
    "FakeProvider",
    "ProbeResult",
    "ProviderValidator",
]
