/**
 * Fix-round tests for the TraceGraph rendering prerequisites (KCC x
 * Superpowers Hybrid Framework Plan 06, Task 3, review round 1).
 *
 * Reviewer finding (Important): ``TraceGraph`` never imported
 * ``@xyflow/react``'s required stylesheet — ``dist/style.css`` carries
 * the ``.react-flow__node`` / ``.react-flow__edge`` absolute-positioning
 * rules — and its ``.trace-graph`` container had no height, so the
 * projection would not render correctly once P06-T04 wires it up.
 * SSR tests and DOM-based checks cannot catch either gap.
 *
 * These tests pin the fix:
 *
 * * importing the ``TraceGraph`` module loads the React Flow
 *   stylesheet (side-effect import, so the bundled app carries the
 *   node/edge absolute-positioning rules);
 * * the ``.trace-graph`` viewport is explicitly sized so the React Flow
 *   projection has a box to paint into.
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

/** Set by the stylesheet mock factory when the module is imported. */
const styleLoad = vi.hoisted(() => ({ reactFlowStylesheetLoaded: false }));

vi.mock("@xyflow/react/dist/style.css", () => {
  styleLoad.reactFlowStylesheetLoaded = true;
  return {};
});

import type { TraceProjection } from "../types";
import { TRACE_GRAPH_HEIGHT_PX, TraceGraph } from "./TraceGraph";

/** A fully covered trace chain (no orphans). */
const DAG: TraceProjection = {
  run_id: "RUN-041",
  nodes: [
    { id: "REQ-014", kind: "requirement" },
    { id: "AC-014-1", kind: "acceptance" },
    { id: "T-041", kind: "test" },
    { id: "PROD-SMOKE-06", kind: "production_validation" },
  ],
  edges: [
    { source: "REQ-014", target: "AC-014-1" },
    { source: "AC-014-1", target: "T-041" },
    { source: "T-041", target: "PROD-SMOKE-06" },
  ],
  coverage: { covered: ["REQ-014"], orphans: [] },
};

describe("TraceGraph loads the React Flow stylesheet", () => {
  it("side-effect imports @xyflow/react's required stylesheet", () => {
    expect(styleLoad.reactFlowStylesheetLoaded).toBe(true);
  });
});

describe("TraceGraph viewport is sized", () => {
  it("gives the .trace-graph container an explicit height", () => {
    const html = renderToStaticMarkup(<TraceGraph projection={DAG} />);
    const wrapper = /<div class="trace-graph"[^>]*>/.exec(html)?.[0] ?? "";
    expect(wrapper).toContain(`height:${TRACE_GRAPH_HEIGHT_PX}px`);
  });
});
