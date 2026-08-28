/**
 * Behavioral tests for the readiness surface (KCC x Superpowers Hybrid
 * Framework Plan 06, Task 4; Design Spec v1.2 sections 12-13
 * "Readiness" and section 15 "Final LOCK Experience").
 *
 * Written first (strict TDD red phase), against the external behavior
 * contract of :file:`src/components/ReadinessPanel.tsx`:
 *
 * * the verdict is the server's readiness evaluation (``ready``), so
 *   the panel can never claim READY for a projection the control plane
 *   declared not ready;
 * * unresolved blockers, open red-team findings and the stale-evidence
 *   state are all visible — they are exactly the inputs of the LOCK
 *   gate;
 * * every readiness item renders its server status and whether its
 *   evidence is current.
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { ReadinessProjection } from "../types";
import { ReadinessPanel } from "./ReadinessPanel";

const READY: ReadinessProjection = {
  ready: true,
  coverage_ok: true,
  blockers: [],
  open_red_team_findings: [],
  evidence_stale: false,
  items: [
    {
      item_id: "PROVIDER-A",
      status: "READY",
      reasons: ["quota confirmed"],
      evidence: [],
      fallbacks: [],
      evidence_current: true,
    },
  ],
};

const NOT_READY: ReadinessProjection = {
  ready: false,
  coverage_ok: true,
  blockers: ["PROVIDER-B", "PROVIDER-C"],
  open_red_team_findings: ["RF-042-1"],
  evidence_stale: true,
  items: [
    {
      item_id: "PROVIDER-B",
      status: "BLOCKER",
      reasons: ["quota exceeded"],
      evidence: [],
      fallbacks: [],
      evidence_current: true,
    },
    {
      item_id: "PROVIDER-C",
      status: "BLOCKER",
      reasons: ["credential revoked"],
      evidence: [],
      fallbacks: [],
      evidence_current: false,
    },
  ],
};

describe("ReadinessPanel verdict", () => {
  it("mirrors the server readiness verdict (never claims READY on its own)", () => {
    const ready = renderToStaticMarkup(<ReadinessPanel readiness={READY} />);
    expect(ready).toContain('data-ready="true"');
    expect(ready).toContain("READY");

    const notReady = renderToStaticMarkup(<ReadinessPanel readiness={NOT_READY} />);
    expect(notReady).toContain('data-ready="false"');
    expect(notReady).toContain("NOT READY");
  });
});

describe("ReadinessPanel blockers and findings", () => {
  it("lists every readiness blocker id", () => {
    const html = renderToStaticMarkup(<ReadinessPanel readiness={NOT_READY} />);
    expect(html).toContain("PROVIDER-B");
    expect(html).toContain("PROVIDER-C");
    expect((html.match(/class="readiness-panel__blocker"/g) ?? []).length).toBe(2);
  });

  it("lists every open red-team finding id", () => {
    const html = renderToStaticMarkup(<ReadinessPanel readiness={NOT_READY} />);
    expect(html).toContain("RF-042-1");
  });

  it("marks stale evidence visibly", () => {
    const html = renderToStaticMarkup(<ReadinessPanel readiness={NOT_READY} />);
    expect(html).toContain("readiness-panel__stale");
  });

  it("shows no blockers for a trouble-free projection", () => {
    const html = renderToStaticMarkup(<ReadinessPanel readiness={READY} />);
    expect(html).not.toContain('class="readiness-panel__blocker"');
  });
});

describe("ReadinessPanel items", () => {
  it("renders every item with its server status and evidence currency", () => {
    const html = renderToStaticMarkup(<ReadinessPanel readiness={NOT_READY} />);
    expect(html).toContain("PROVIDER-B");
    expect(html).toContain("BLOCKER");
    expect(html).toContain('data-evidence-current="true"');
    expect(html).toContain('data-evidence-current="false"');
  });
});
