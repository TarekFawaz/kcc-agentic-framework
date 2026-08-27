"""Behavioral tests for the autobuild trace graph layer.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.trace` (see the KCC x Superpowers Hybrid
Framework Plan 02, Task 1).

A trace graph is a typed DAG of nodes/edges.  Every requirement is
covered only when forward traversal reaches BOTH an acceptance node and
a production_validation node; anything else is an orphan.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from kcc_autobuild.trace import (
    TraceCoverageResult,
    TraceEdge,
    TraceGraph,
    TraceNode,
    validate_trace_coverage,
)


def _node(node_id: str, kind: str) -> TraceNode:
    return TraceNode(id=node_id, kind=kind)


def test_pass_case_reaches_acceptance_and_production() -> None:
    """A requirement reaching both AC and PROD nodes is fully covered."""
    graph = TraceGraph(
        nodes=[
            _node("REQ-001", "requirement"),
            _node("IMPL-01", "implementation"),
            _node("AC-001", "acceptance"),
            _node("PROD-001", "production_validation"),
        ],
        edges=[
            TraceEdge(source="REQ-001", target="IMPL-01"),
            TraceEdge(source="IMPL-01", target="AC-001"),
            TraceEdge(source="IMPL-01", target="PROD-001"),
        ],
    )
    result = validate_trace_coverage(graph)
    assert isinstance(result, TraceCoverageResult)
    assert result.orphans == []
    assert result.covered == ["REQ-001"]


def test_missing_production_validation_is_orphan() -> None:
    """A requirement reaching AC but no PROD node is an orphan."""
    graph = TraceGraph(
        nodes=[
            _node("REQ-001", "requirement"),
            _node("AC-001", "acceptance"),
        ],
        edges=[TraceEdge(source="REQ-001", target="AC-001")],
    )
    result = validate_trace_coverage(graph)
    assert result.orphans == ["REQ-001"]
    assert result.covered == []


def test_orphans_are_sorted() -> None:
    """Orphaned requirements are reported in sorted id order."""
    graph = TraceGraph(
        nodes=[
            _node("REQ-002", "requirement"),
            _node("REQ-001", "requirement"),
            _node("PROD-001", "production_validation"),
        ],
        edges=[TraceEdge(source="REQ-002", target="PROD-001")],
    )
    result = validate_trace_coverage(graph)
    assert result.orphans == ["REQ-001", "REQ-002"]
    assert result.covered == []


def test_duplicate_node_ids_rejected() -> None:
    """Duplicate node ids cannot form an unambiguous graph."""
    with pytest.raises(ValidationError):
        TraceGraph(
            nodes=[
                _node("REQ-001", "requirement"),
                _node("REQ-001", "acceptance"),
            ],
            edges=[],
        )


@pytest.mark.parametrize(
    "edge",
    [
        TraceEdge(source="A", target="MISSING"),
        TraceEdge(source="MISSING", target="A"),
    ],
)
def test_dangling_edge_rejected(edge: TraceEdge) -> None:
    """Edges must reference existing nodes on both ends."""
    with pytest.raises(ValidationError):
        TraceGraph(
            nodes=[_node("A", "requirement")],
            edges=[edge],
        )


def test_cycle_rejected() -> None:
    """Trace graphs must be acyclic."""
    with pytest.raises(ValidationError):
        TraceGraph(
            nodes=[
                _node("A", "requirement"),
                _node("B", "implementation"),
            ],
            edges=[
                TraceEdge(source="A", target="B"),
                TraceEdge(source="B", target="A"),
            ],
        )


def test_run_id_optional_and_pattern_validated() -> None:
    """run_id is optional; when present it must match RUN_ID_PATTERN."""
    graph = TraceGraph(run_id="RUN-001", nodes=[], edges=[])
    assert graph.run_id == "RUN-001"

    assert TraceGraph(nodes=[], edges=[]).run_id is None

    with pytest.raises(ValidationError):
        TraceGraph(run_id="bad-id", nodes=[], edges=[])
