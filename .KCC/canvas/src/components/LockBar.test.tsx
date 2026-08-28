/**
 * Behavioral tests for the LOCK & BUILD surface (KCC x Superpowers
 * Hybrid Framework Plan 06, Task 4; Design Spec v1.2 section 15
 * "Final LOCK Experience"; plan Global Constraints on stale-state
 * discipline).
 *
 * Written first (strict TDD red phase), against the external behavior
 * contract of :file:`src/components/LockBar.tsx`:
 *
 * * LOCK is enabled ONLY when the run state is exactly
 *   ``CONTRACT_REVIEW``, the readiness projection has zero blockers
 *   (``blocker_count = 0``) and its evidence is not stale — any other
 *   state, any blocker, or stale evidence disables the button and
 *   surfaces the reason;
 * * a missing Tier-1 contract hash also disables LOCK (the command
 *   must prove the hash, so no hash means no request to send);
 * * PAUSE is enabled only for a BUILDING run and RESUME only for a
 *   PAUSED run, mirroring the control-plane transitions.
 *
 * The component is rendered to static markup with ``react-dom/server``
 * and the gating logic is exercised as pure functions over every
 * canonical lifecycle state.
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

import { LIFECYCLE_STATES, type LifecycleState, type ReadinessProjection } from "../types";
import {
  LOCK_BUTTON_LABEL,
  LOCK_EXPECTED_STATE,
  LockBar,
  lockGate,
  pauseEnabled,
  resumeEnabled,
} from "./LockBar";

const TIER1_HASH = "a".repeat(64);

/** A readiness projection with no blockers and current evidence. */
const READY_READINESS: ReadinessProjection = {
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

/** A readiness projection with one unresolved blocker. */
const BLOCKED_READINESS: ReadinessProjection = {
  ready: false,
  coverage_ok: true,
  blockers: ["PROVIDER-B"],
  open_red_team_findings: [],
  evidence_stale: false,
  items: [
    {
      item_id: "PROVIDER-B",
      status: "BLOCKER",
      reasons: ["quota exceeded"],
      evidence: [],
      fallbacks: [],
      evidence_current: true,
    },
  ],
};

/** A readiness projection whose evidence has gone stale. */
const STALE_READINESS: ReadinessProjection = {
  ready: false,
  coverage_ok: true,
  blockers: [],
  open_red_team_findings: [],
  evidence_stale: true,
  items: [
    {
      item_id: "PROVIDER-A",
      status: "READY",
      reasons: [],
      evidence: [],
      fallbacks: [],
      evidence_current: false,
    },
  ],
};

function lockButtonTag(html: string): string {
  return /<button class="lock-bar__button"[^>]*>/.exec(html)?.[0] ?? "";
}

function renderBar(
  state: LifecycleState,
  readiness: ReadinessProjection | null,
  tier1Hash: string | null,
): string {
  return renderToStaticMarkup(
    <LockBar
      state={state}
      readiness={readiness}
      tier1Hash={tier1Hash}
      busy={false}
      error={null}
      staleRefreshed={false}
      onLock={vi.fn()}
      onPause={vi.fn()}
      onResume={vi.fn()}
    />,
  );
}

describe("lockGate state precondition", () => {
  it("allows LOCK only when the run is exactly in CONTRACT_REVIEW", () => {
    expect(LOCK_EXPECTED_STATE).toBe("CONTRACT_REVIEW");
    const gate = lockGate("CONTRACT_REVIEW", READY_READINESS, TIER1_HASH);
    expect(gate.enabled).toBe(true);
    expect(gate.reasons).toEqual([]);
  });

  it("disables LOCK for every other lifecycle state, naming the expectation", () => {
    const otherStates = LIFECYCLE_STATES.filter((state) => state !== "CONTRACT_REVIEW");
    expect(otherStates.length).toBeGreaterThan(0);
    for (const state of otherStates) {
      const gate = lockGate(state, READY_READINESS, TIER1_HASH);
      expect(gate.enabled).toBe(false);
      expect(gate.reasons[0]).toBe(
        `LOCK expects CONTRACT_REVIEW (current: ${state})`,
      );
    }
  });
});

describe("lockGate blocker and evidence preconditions", () => {
  it("disables LOCK while the readiness projection has blockers", () => {
    const gate = lockGate("CONTRACT_REVIEW", BLOCKED_READINESS, TIER1_HASH);
    expect(gate.enabled).toBe(false);
    expect(gate.reasons.some((reason) => reason.includes("1 blocker"))).toBe(true);
    expect(gate.reasons.some((reason) => reason.includes("PROVIDER-B"))).toBe(true);
  });

  it("disables LOCK when readiness evidence is stale", () => {
    const gate = lockGate("CONTRACT_REVIEW", STALE_READINESS, TIER1_HASH);
    expect(gate.enabled).toBe(false);
    expect(gate.reasons).toContain("readiness evidence is stale");
  });

  it("disables LOCK when the readiness projection is not loaded", () => {
    const gate = lockGate("CONTRACT_REVIEW", null, TIER1_HASH);
    expect(gate.enabled).toBe(false);
    expect(gate.reasons).toContain("readiness not loaded");
  });

  it("disables LOCK when the contract has no Tier-1 hash to prove", () => {
    const gate = lockGate("CONTRACT_REVIEW", READY_READINESS, null);
    expect(gate.enabled).toBe(false);
    expect(gate.reasons.some((reason) => reason.includes("Tier-1 hash"))).toBe(true);
  });
});

describe("LockBar renders the gated surface", () => {
  it("renders an enabled LOCK button only when the gate allows it", () => {
    const enabledHtml = renderBar("CONTRACT_REVIEW", READY_READINESS, TIER1_HASH);
    // SSR escapes the ampersand; the visible text is the canonical label.
    expect(enabledHtml).toContain("LOCK &amp; BUILD");
    expect(LOCK_BUTTON_LABEL).toBe("LOCK & BUILD");
    expect(lockButtonTag(enabledHtml)).not.toContain("disabled");

    const disabledHtml = renderBar("BUILDING", READY_READINESS, TIER1_HASH);
    expect(lockButtonTag(disabledHtml)).toContain("disabled");
  });

  it("renders the blocking reason list for an invalid state and for blockers", () => {
    const html = renderBar("LOCKED", BLOCKED_READINESS, TIER1_HASH);
    expect(html).toContain("LOCK expects CONTRACT_REVIEW (current: LOCKED)");
    expect(html).toContain("1 blocker");
    expect(html).toContain("PROVIDER-B");
  });

  it("renders the stale notice after a stale projection refresh", () => {
    const html = renderToStaticMarkup(
      <LockBar
        state="CONTRACT_REVIEW"
        readiness={READY_READINESS}
        tier1Hash={TIER1_HASH}
        busy={false}
        error={null}
        staleRefreshed={true}
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
    expect(html).toContain("lock-bar__stale-notice");
    expect(html).toContain("refreshed");
  });

  it("surfaces command errors for the user without swallowing them", () => {
    const html = renderToStaticMarkup(
      <LockBar
        state="CONTRACT_REVIEW"
        readiness={READY_READINESS}
        tier1Hash={TIER1_HASH}
        busy={false}
        error="409 STALE_CONTRACT - tier1_hash does not match"
        staleRefreshed={false}
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
    expect(html).toContain('role="alert"');
    expect(html).toContain("STALE_CONTRACT");
  });
});

describe("pause/resume gating mirrors the control plane", () => {
  it("enables PAUSE only for a BUILDING run", () => {
    for (const state of LIFECYCLE_STATES) {
      expect(pauseEnabled(state)).toBe(state === "BUILDING");
    }
  });

  it("enables RESUME only for a PAUSED run", () => {
    for (const state of LIFECYCLE_STATES) {
      expect(resumeEnabled(state)).toBe(state === "PAUSED");
    }
  });

  it("renders PAUSE enabled and RESUME disabled for BUILDING (and the reverse for PAUSED)", () => {
    const building = renderBar("BUILDING", READY_READINESS, TIER1_HASH);
    expect(/<button class="lock-bar__pause"[^>]*>/.exec(building)?.[0] ?? "").not.toContain(
      "disabled",
    );
    expect(/<button class="lock-bar__resume"[^>]*>/.exec(building)?.[0] ?? "").toContain(
      "disabled",
    );

    const paused = renderBar("PAUSED", READY_READINESS, TIER1_HASH);
    expect(/<button class="lock-bar__pause"[^>]*>/.exec(paused)?.[0] ?? "").toContain(
      "disabled",
    );
    expect(/<button class="lock-bar__resume"[^>]*>/.exec(paused)?.[0] ?? "").not.toContain(
      "disabled",
    );
  });
});
