/**
 * Immutable React Flow projection of the server-owned trace graph.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 3 (Design Spec v1.2
 * sections 10 "The Trace Matrix" / 10.3 "Orphan rule"):
 *
 * * the projection is server-owned: :func:`traceFlowNodes` /
 *   :func:`traceFlowEdges` map the exact ``TraceProjection`` node and
 *   edge sets (ids, kinds, coverage) — nothing is invented, nothing
 *   is dropped.  The API publishes no coordinates, so positions come
 *   from :func:`layoutTraceGraph`, a deterministic pure layout of the
 *   server DAG (levels along ``x``, same-level spread along ``y``);
 * * orphan requirement ids (``coverage.orphans``) render a BLOCKER
 *   badge — an orphan requirement blocks LOCK until it is traced to an
 *   acceptance criterion and a production validation;
 * * the graph is display-only: every node is rendered with the
 *   drag / select / connect / delete / focus affordances disabled,
 *   the React Flow projection gets the read-only interaction props
 *   (:data:`TRACE_GRAPH_READONLY_PROPS`) and the component wires no
 *   ``onNodesChange`` / ``onEdgesChange`` / ``onConnect`` handler and
 *   keeps no node/edge state.  There is therefore no client-side graph
 *   mutation and nothing to persist — the server projection can never
 *   be dragged or edited away.
 */
import { useMemo } from "react";
import {
  Background,
  ReactFlow,
  type Edge,
  type Node,
  type NodeProps,
  type NodeTypes,
  type XYPosition,
} from "@xyflow/react";

import type { NodeKind, TraceEdge, TraceNode, TraceProjection } from "../types";

/** Horizontal distance between refinement levels. */
export const TRACE_LAYOUT_X_GAP = 280;

/** Vertical distance between nodes of the same level. */
export const TRACE_LAYOUT_Y_GAP = 130;

/** Data carried by one trace node in the React Flow projection. */
export interface TraceNodeData extends Record<string, unknown> {
  /** Visible label: the server node id (never client-generated). */
  label: string;
  kind: NodeKind;
  /** True when server coverage classifies this id as an orphan. */
  orphan: boolean;
}

export type TraceFlowNode = Node<TraceNodeData>;
export type TraceFlowEdge = Edge;

/**
 * Deterministic DAG layout: longest-path levels along ``x``, then
 * same-level nodes spread along ``y`` (id order), so the same server
 * projection always renders identically.
 */
export function layoutTraceGraph(
  nodes: TraceNode[],
  edges: TraceEdge[],
): Map<string, XYPosition> {
  const level = new Map<string, number>(nodes.map((node) => [node.id, 0]));
  const indegree = new Map<string, number>(nodes.map((node) => [node.id, 0]));
  const children = new Map<string, string[]>(
    nodes.map((node) => [node.id, []]),
  );
  for (const edge of edges) {
    if (!level.has(edge.source) || !level.has(edge.target)) {
      continue;
    }
    children.get(edge.source)?.push(edge.target);
    indegree.set(edge.target, (indegree.get(edge.target) ?? 0) + 1);
  }
  const ready = nodes
    .map((node) => node.id)
    .filter((id) => (indegree.get(id) ?? 0) === 0)
    .sort();
  while (ready.length > 0) {
    const id = ready.shift() as string;
    const nodeLevel = level.get(id) ?? 0;
    for (const child of children.get(id) ?? []) {
      level.set(child, Math.max(level.get(child) ?? 0, nodeLevel + 1));
      const remaining = (indegree.get(child) ?? 0) - 1;
      indegree.set(child, remaining);
      if (remaining === 0) {
        const position = ready.findIndex((other) => child < other);
        if (position === -1) {
          ready.push(child);
        } else {
          ready.splice(position, 0, child);
        }
      }
    }
  }
  const positions = new Map<string, XYPosition>();
  for (const node of nodes) {
    const nodeLevel = level.get(node.id) ?? 0;
    const column = [...nodes.values()]
      .filter((candidate) => (level.get(candidate.id) ?? 0) === nodeLevel)
      .map((candidate) => candidate.id)
      .sort();
    const row = column.indexOf(node.id);
    positions.set(node.id, {
      x: nodeLevel * TRACE_LAYOUT_X_GAP,
      y: row * TRACE_LAYOUT_Y_GAP,
    });
  }
  return positions;
}

/** The React Flow nodes of the server trace projection (read-only). */
export function traceFlowNodes(projection: TraceProjection): TraceFlowNode[] {
  const orphanIds = new Set(projection.coverage.orphans);
  const positions = layoutTraceGraph(projection.nodes, projection.edges);
  return projection.nodes.map((node) => ({
    id: node.id,
    type: "trace",
    draggable: false,
    selectable: false,
    connectable: false,
    deletable: false,
    focusable: false,
    position: positions.get(node.id) ?? { x: 0, y: 0 },
    data: {
      label: node.id,
      kind: node.kind,
      orphan: orphanIds.has(node.id),
    },
  }));
}

/** The React Flow edges of the server trace projection (read-only). */
export function traceFlowEdges(projection: TraceProjection): TraceFlowEdge[] {
  const seen = new Map<string, number>();
  return projection.edges.map((edge) => {
    const key = `${edge.source}->${edge.target}`;
    const occurrence = seen.get(key) ?? 0;
    seen.set(key, occurrence + 1);
    return {
      id: occurrence === 0 ? key : `${key}#${occurrence}`,
      source: edge.source,
      target: edge.target,
    };
  });
}

function TraceFlowNodeView({ data }: NodeProps<TraceFlowNode>) {
  return (
    <div className="trace-node-card" data-orphan={data.orphan ? "true" : "false"}>
      <span className="trace-node-id">{data.label}</span>
      <span className="trace-node-kind">{data.kind}</span>
      {data.orphan ? <span className="trace-orphan-badge">BLOCKER</span> : null}
    </div>
  );
}

const TRACE_NODE_TYPES: NodeTypes = { trace: TraceFlowNodeView };

/**
 * Interaction props that make the React Flow projection read-only:
 * no node dragging, no connecting, no selection/focus mutation and no
 * keyboard edit instructions.
 */
export const TRACE_GRAPH_READONLY_PROPS = {
  nodesDraggable: false,
  nodesConnectable: false,
  elementsSelectable: false,
  nodesFocusable: false,
  disableKeyboardA11y: true,
} as const;

/**
 * The trace graph as a display-only React Flow projection of exactly
 * the server-provided ``TraceProjection``.
 */
export function TraceGraph({ projection }: { projection: TraceProjection }) {
  const nodes = useMemo(() => traceFlowNodes(projection), [projection]);
  const edges = useMemo(() => traceFlowEdges(projection), [projection]);
  return (
    <div
      className="trace-graph"
      aria-label={`Autobuild trace graph for run ${projection.run_id ?? "unknown"}`}
    >
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={TRACE_NODE_TYPES}
        fitView
        {...TRACE_GRAPH_READONLY_PROPS}
      >
        <Background />
      </ReactFlow>
    </div>
  );
}
