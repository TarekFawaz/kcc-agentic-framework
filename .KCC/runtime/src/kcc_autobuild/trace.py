"""Trace graph model for the autobuild framework.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_trace.py`
(see the KCC x Superpowers Hybrid Framework Plan 02, Task 1).

A trace is a typed DAG of nodes (requirements, journeys, flows, screens,
components, apis, data, dependencies, implementations, acceptances,
tests, observability, production validations) with directed edges
expressing refinement/derivation.  Every requirement is covered only
when forward traversal reaches BOTH an acceptance node and a
production_validation node.

The shape of the trace graph is shared with the approved trace-graph
YAML template: the optional :attr:`TraceGraph.run_id` is validated
against the canonical run identity pattern when present.
"""

from __future__ import annotations

from collections import defaultdict, deque
from typing import Literal

from pydantic import Field, model_validator

from kcc_autobuild.models import RUN_ID_PATTERN, StrictModel

NodeKind = Literal[
    "requirement",
    "journey",
    "flow",
    "screen",
    "component",
    "api",
    "data",
    "dependency",
    "implementation",
    "acceptance",
    "test",
    "observability",
    "production_validation",
]
"""Valid kinds of a trace node."""


class TraceNode(StrictModel):
    """A typed node in an autobuild trace graph."""

    id: str
    kind: NodeKind


class TraceEdge(StrictModel):
    """A directed refinement edge between two trace nodes."""

    source: str
    target: str


class TraceGraph(StrictModel):
    """A validated DAG of trace nodes and edges.

    Validation on construction:

    * `:attr:`run_id` must match RUN_ID_PATTERN when provided;
    * node ids are unique;
    * every edge source/target references an existing node;
    * the graph is acyclic (checked via Kahn's indegree traversal).
    """

    run_id: str | None = Field(default=None, pattern=RUN_ID_PATTERN)
    nodes: list[TraceNode] = Field(default_factory=list)
    edges: list[TraceEdge] = Field(default_factory=list)

    @model_validator(mode="after")
    def _validate_graph(self) -> TraceGraph:
        ids = [node.id for node in self.nodes]
        if len(ids) != len(set(ids)):
            raise ValueError("trace node ids must be unique")
        known = set(ids)
        for edge in self.edges:
            if edge.source not in known:
                raise ValueError(
                    f"edge source '{edge.source}' does not reference an existing node"
                )
            if edge.target not in known:
                raise ValueError(
                    f"edge target '{edge.target}' does not reference an existing node"
                )
        self._assert_acyclic()
        return self

    def _assert_acyclic(self) -> None:
        adjacency: dict[str, list[str]] = defaultdict(list)
        indegree: dict[str, int] = {node.id: 0 for node in self.nodes}
        for edge in self.edges:
            adjacency[edge.source].append(edge.target)
            indegree[edge.target] += 1
        queue = deque(
            node_id for node_id, degree in indegree.items() if degree == 0
        )
        visited = 0
        while queue:
            node_id = queue.popleft()
            visited += 1
            for child in adjacency[node_id]:
                indegree[child] -= 1
                if indegree[child] == 0:
                    queue.append(child)
        if visited != len(indegree):
            raise ValueError("trace graph must be acyclic")


class TraceCoverageResult(StrictModel):
    """Result of a forward trace coverage check.

    Both lists are sorted by requirement id for deterministic output.
    """

    covered: list[str] = Field(default_factory=list)
    orphans: list[str] = Field(default_factory=list)


def validate_trace_coverage(graph: TraceGraph) -> TraceCoverageResult:
    """Traverse forward from every requirement and classify coverage.

    A requirement is covered only if it can reach BOTH an
    `acceptance` node and a `production_validation` node through
    forward edges; otherwise it is an orphan.  Result lists are sorted.
    """
    adjacency: dict[str, list[str]] = defaultdict(list)
    for edge in graph.edges:
        adjacency[edge.source].append(edge.target)

    kind_by_id = {node.id: node.kind for node in graph.nodes}
    covered: list[str] = []
    orphans: list[str] = []

    for node in graph.nodes:
        if node.kind != "requirement":
            continue
        reached_kinds: set[str] = set()
        seen: set[str] = {node.id}
        reached_kinds.add(node.kind)
        queue: deque[str] = deque([node.id])
        while queue:
            current = queue.popleft()
            for child in adjacency[current]:
                if child in seen:
                    continue
                seen.add(child)
                reached_kinds.add(kind_by_id[child])
                queue.append(child)
        if "acceptance" in reached_kinds and "production_validation" in reached_kinds:
            covered.append(node.id)
        else:
            orphans.append(node.id)

    return TraceCoverageResult(covered=sorted(covered), orphans=sorted(orphans))
