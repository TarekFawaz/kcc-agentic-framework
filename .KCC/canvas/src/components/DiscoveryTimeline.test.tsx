/**
 * Behavioral tests for the discovery timeline (KCC x Superpowers Hybrid
 * Framework Plan 06, Task 3; Design Spec v1.2 section 7 "Phase Model").
 *
 * Written first (strict TDD red phase), against the external behavior
 * contract of :file:`src/components/DiscoveryTimeline.tsx`:
 *
 * * the timeline renders the seven pre-lock discovery phases
 *   (INTAKE / DISCOVERY / PROTOTYPE_REVIEW / ARCHITECTURE / DE_RISK /
 *   READINESS / CONTRACT_REVIEW) in canonical order;
 * * exactly the phase the run is currently in carries
 *   ``aria-current="step"``;
 * * a run that has left the discovery phases (LOCKED / BUILDING / ... /
 *   ABANDONED) has no current phase: the discovery timeline is
 *   finished.
 *
 * The components are rendered to static markup with ``react-dom/server``
 * (no DOM required), so the assertions inspect the real accessible
 * output of the component.
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { LifecycleState } from "../types";
import {
  DiscoveryTimeline,
  TIMELINE_PHASES,
  currentTimelinePhase,
} from "./DiscoveryTimeline";

/** Every state that is not one of the seven discovery phases. */
const OUTSIDE_DISCOVERY: LifecycleState[] = [
  "LOCKED",
  "BUILDING",
  "STAGING_VALIDATED",
  "DEPLOYED",
  "PRODUCTION_VALIDATED",
  "DONE",
  "BLOCKED",
  "EXTERNAL_WAIT",
  "PAUSED",
  "HALTED",
  "ROLLING_BACK",
  "RESUMING",
  "ABANDONED",
];

function timelineHtml(state: LifecycleState): string {
  return renderToStaticMarkup(<DiscoveryTimeline state={state} />);
}

interface PhaseItem {
  phase: string;
  active: boolean;
}

function phaseItems(html: string): PhaseItem[] {
  return [...html.matchAll(/<li\b[^>]*>/g)].map((match) => {
    const tag = match[0] ?? "";
    const phase = /data-phase="([A-Z_]+)"/.exec(tag)?.[1] ?? "";
    return { phase, active: tag.includes('aria-current="step"') };
  });
}

describe("DiscoveryTimeline", () => {
  it("renders the seven discovery phases in canonical order", () => {
    const items = phaseItems(timelineHtml("INTAKE"));
    expect(items.map((item) => item.phase)).toEqual([...TIMELINE_PHASES]);
  });

  it("puts aria-current on exactly the active phase of the run", () => {
    for (const phase of TIMELINE_PHASES) {
      const items = phaseItems(timelineHtml(phase));
      const current = items.filter((item) => item.active);
      expect(current.map((item) => item.phase)).toEqual([phase]);
      expect(items.filter((item) => item.phase === phase)).toHaveLength(1);
    }
  });

  it("marks no phase when the run is outside the discovery phases", () => {
    for (const state of OUTSIDE_DISCOVERY) {
      expect(phaseItems(timelineHtml(state)).some((item) => item.active)).toBe(
        false,
      );
    }
  });

  it("maps discovery states to their phase and the rest to none", () => {
    for (const phase of TIMELINE_PHASES) {
      expect(currentTimelinePhase(phase)).toBe(phase);
    }
    expect(currentTimelinePhase("LOCKED")).toBeNull();
    expect(currentTimelinePhase("BUILDING")).toBeNull();
    expect(currentTimelinePhase("ABANDONED")).toBeNull();
  });
});
