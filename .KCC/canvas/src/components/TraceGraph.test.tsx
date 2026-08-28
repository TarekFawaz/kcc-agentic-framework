/**
 * Behavioral tests for the immutable React Flow trace graph (KCC x
 * Superpowers Hybrid Framework Plan 06, Task 3; Design Spec v1.2
 * section 10 "The Trace Matrix" and section 10.3 "Orphan rule").
 *
 * Written first (strict TDD red phase), against the external behavior
 * contract of :file:`src/components/TraceGraph.tsx`:
 *
 * * the React Flow projection is server-owned: exactly the server's
 *   node and edge ids are rendered — nothing is invented, nothing is
 *   dropped, and positions are a deterministic layout of the server
 *   DAG;
 * * orphan requirement ids (``coverage.orphans``) render a BLOCKER
 *   badge; covered nodes never do;
 * * the graph is display-only: nodes carry no drag / select / connect /
 *   focus affordances, the keyboard edit instructions are not rendered
 *   and no client-side graph state exists — there are no persisted
 *   drag/edit graph mutations.
 *
 * The component is rendered to static markup with ``react-dom/server``
 * (no DOM required); React Flow itself renders into that markup.
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { TraceProjection } from "../types";
import {
  TraceGraph,
  TRACE_GRAPH_READONLY_PROPS,
  traceFlowEdges,
  traceFlowNodes,
} from "./TraceGraph";

/** A fully covered trace chain (no orphans). */
const DAG: TraceProjection = {
  run_id: "RUN-041",
  nodes: [
    { id: "REQ-014", kind: "requirement" },
    { id: "JOURNEY-03", kind: "journey" },
    { id: "SCREEN-04", kind: "screen" },
    { id: "AC-014-1", kind: "acceptance" },
    { id: "T-041", kind: "test" },
    { id: "PROD-SMOKE-06", kind: "production_validation" },
  ],
  edges: [
    { source: "REQ-014", target: "JOURNEY-03" },
    { source: "JOURNEY-03", target: "SCREEN-04" },
    { source: "SCREEN-04", target: "AC-014-1" },
    { source: "AC-014-1", target: "T-041" },
    { source: "T-041", target: "PROD-SMOKE-06" },
  ],
  coverage: { covered: ["REQ-014"], orphans: [] },
};

/** One covered requirement plus one orphan requirement (REQ-015). */
const MIXED: TraceProjection = {
  run_id: "RUN-041",
  nodes: [
    { id: "REQ-014", kind: "requirement" },
    { id: "AC-014-1", kind: "acceptance" },
    { id: "PROD-SMOKE-06", kind: "production_validation" },
    { id: "REQ-015", kind: "requirement" },
    { id: "SCREEN-08", kind: "screen" },
  ],
  edges: [
    { source: "REQ-014", target: "AC-014-1" },
    { source: "REQ-014", target: "PROD-SMOKE-06" },
    { source: "REQ-015", target: "SCREEN-08" },
  ],
  coverage: { covered: ["REQ-014"], orphans: ["REQ-015"] },
};

function renderedNodeIds(html: string): string[] {
  return [...html.matchAll(/data-testid="rf__node-([^"]+)"/g)].map(
    (match) => match[1] ?? "",
  );
}

/** Markup of exactly one node (from its marker to the next node's marker). */
function nodeMarkup(html: string, id: string): string {
  const marker = `data-testid="rf__node-${id}"`;
  const start = html.indexOf(marker);
  const remainder = html.slice(start + marker.length);
  const next = remainder.search(/data-testid="rf__node-/);
  return remainder.slice(0, next === -1 ? remainder.length : next);
}

describe("traceFlowNodes mirror the server projection", () => {
  it("mirrors the server node set exactly (no invention, no omission)", () => {
    expect(traceFlowNodes(MIXED).map((node) => node.id)).toEqual(
      MIXED.nodes.map((node) => node.id),
    );
  });

  it("carries the server id and kind, labelled with the server id", () => {
    const byId = new Map(traceFlowNodes(MIXED).map((node) => [node.id, node]));
    expect(byId.get("REQ-015")?.data.label).toBe("REQ-015");
    expect(byId.get("REQ-015")?.data.kind).toBe("requirement");
    expect(byId.get("AC-014-1")?.data.kind).toBe("acceptance");
  });

  it("flags exactly the coverage orphans", () => {
    const byId = new Map(traceFlowNodes(MIXED).map((node) => [node.id, node]));
    expect(byId.get("REQ-015")?.data.orphan).toBe(true);
    expect(byId.get("REQ-014")?.data.orphan).toBe(false);
    expect(byId.get("SCREEN-08")?.data.orphan).toBe(false);
  });

  it("assigns deterministic positions (same projection, same layout)", () => {
    expect(traceFlowNodes(MIXED).map((node) => node.position)).toEqual(
      traceFlowNodes(MIXED).map((node) => node.position),
    );
  });

  it("lays every child strictly to the right of its parent", () => {
    const byId = new Map(traceFlowNodes(DAG).map((node) => [node.id, node]));
    for (const edge of DAG.edges) {
      const source = byId.get(edge.source);
      const target = byId.get(edge.target);
      expect(source).toBeDefined();
      expect(target).toBeDefined();
      expect((target as { position: { x: number } }).position.x).toBeGreaterThan(
        (source as { position: { x: number } }).position.x,
      );
    }
  });

  it("spreads same-level nodes vertically", () => {
    const byId = new Map(traceFlowNodes(MIXED).map((node) => [node.id, node]));
    expect(byId.get("REQ-014")?.position.y).not.toBe(
      byId.get("REQ-015")?.position.y,
    );
  });

  it("renders every node read-only: no drag/select/connect/focus affordances", () => {
    for (const node of traceFlowNodes(MIXED)) {
      expect(node.draggable).toBe(false);
      expect(node.selectable).toBe(false);
      expect(node.connectable).toBe(false);
      expect(node.deletable).toBe(false);
      expect(node.focusable).toBe(false);
    }
  });
});

describe("traceFlowEdges mirror the server projection", () => {
  it("mirrors the server edge set exactly", () => {
    const pairs = traceFlowEdges(DAG).map((edge) => [edge.source, edge.target]);
    expect(pairs).toEqual(DAG.edges.map((edge) => [edge.source, edge.target]));
  });

  it("gives every edge a stable unique id", () => {
    const ids = traceFlowEdges(DAG).map((edge) => edge.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).toEqual([
      "REQ-014->JOURNEY-03",
      "JOURNEY-03->SCREEN-04",
      "SCREEN-04->AC-014-1",
      "AC-014-1->T-041",
      "T-041->PROD-SMOKE-06",
    ]);
  });
});

describe("TraceGraph renders the server-owned projection", () => {
  it("renders exactly the server node ids", () => {
    const html = renderToStaticMarkup(<TraceGraph projection={MIXED} />);
    const rendered = renderedNodeIds(html);
    expect(rendered.length).toBe(MIXED.nodes.length);
    expect(new Set(rendered)).toEqual(new Set(MIXED.nodes.map((n) => n.id)));
  });

  it("shows the BLOCKER badge on orphan nodes only", () => {
    const html = renderToStaticMarkup(<TraceGraph projection={MIXED} />);
    expect(nodeMarkup(html, "REQ-015")).toContain("trace-orphan-badge");
    expect(nodeMarkup(html, "REQ-015")).toContain("BLOCKER");
    expect(nodeMarkup(html, "REQ-014")).not.toContain("BLOCKER");
    expect((html.match(/trace-orphan-badge/g) ?? []).length).toBe(
      MIXED.coverage.orphans.length,
    );
  });

  it("renders no keyboard edit affordances (the graph is display-only)", () => {
    const html = renderToStaticMarkup(<TraceGraph projection={MIXED} />);
    expect(html).not.toContain("move the node around");
    expect(html).not.toContain('tabindex="0"');
  });

  it("applies the read-only interaction props to the React Flow projection", () => {
    expect(TRACE_GRAPH_READONLY_PROPS).toEqual({
      nodesDraggable: false,
      nodesConnectable: false,
      elementsSelectable: false,
      nodesFocusable: false,
      disableKeyboardA11y: true,
    });
  });
});
