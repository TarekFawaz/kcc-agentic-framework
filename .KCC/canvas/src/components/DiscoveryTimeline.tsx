/**
 * Discovery phase timeline for the autobuild canvas.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 3 (Design Spec v1.2
 * section 7 "Phase Model"): the timeline shows the seven pre-lock
 * discovery phases in canonical order (P0 INTAKE -> P1 DISCOVERY /
 * PROTOTYPE_REVIEW / ARCHITECTURE -> P2 DE_RISK / READINESS -> P3
 * CONTRACT_REVIEW) and puts ``aria-current="step"`` on exactly the
 * phase the run is currently in.
 *
 * A run whose state is not one of the seven discovery phases (LOCKED /
 * BUILDING / ... / ABANDONED) has no current phase: the run has left
 * discovery, either by locking or by abandoning it, so no timeline
 * item carries ``aria-current``.
 */
import { LIFECYCLE_STATES, type LifecycleState } from "../types";

/**
 * The seven pre-lock discovery phases in canonical order.
 *
 * Derived from the canonical lifecycle state mirror
 * (:data:`LIFECYCLE_STATES`): the discovery phases are exactly the
 * first seven lifecycle states (INTAKE .. CONTRACT_REVIEW), before
 * LOCKED.  Each member is indexed off the canonical source so the
 * timeline can never drift from the runtime ordering.
 */
export const TIMELINE_PHASES = [
  LIFECYCLE_STATES[0],
  LIFECYCLE_STATES[1],
  LIFECYCLE_STATES[2],
  LIFECYCLE_STATES[3],
  LIFECYCLE_STATES[4],
  LIFECYCLE_STATES[5],
  LIFECYCLE_STATES[6],
] as const;

export type TimelinePhase = (typeof TIMELINE_PHASES)[number];

/** The discovery phase a run state maps to, or ``null`` outside discovery. */
export function currentTimelinePhase(state: LifecycleState): TimelinePhase | null {
  return TIMELINE_PHASES.find((phase) => phase === state) ?? null;
}

export function DiscoveryTimeline({ state }: { state: LifecycleState }) {
  const active = currentTimelinePhase(state);
  return (
    <ol className="discovery-timeline" aria-label="Autobuild discovery phases">
      {TIMELINE_PHASES.map((phase) => (
        <li
          key={phase}
          data-phase={phase}
          aria-current={phase === active ? "step" : undefined}
          className={
            phase === active
              ? "discovery-timeline__phase discovery-timeline__phase--active"
              : "discovery-timeline__phase"
          }
        >
          {phase}
        </li>
      ))}
    </ol>
  );
}
