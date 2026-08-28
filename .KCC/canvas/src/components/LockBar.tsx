/**
 * LOCK & BUILD surface for the autobuild canvas.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 4 (Design Spec v1.2
 * section 15 "Final LOCK Experience"; spec 13.1 "Readiness taxonomy";
 * plan Global Constraints on stale-state discipline).  LOCK & BUILD is
 * the final formal pre-build authorization, so the bar is gated
 * strictly and in parity with the server-side ``lock_contract``
 * readiness gate:
 *
 * * :func:`lockGate` enables LOCK only when the run state is exactly
 *   ``CONTRACT_REVIEW`` (LOCK is never offered outside the final
 *   review phase), the readiness projection is a READY verdict
 *   (evidence coverage exists, zero blockers, zero open red-team
 *   findings — spec 13.1: "BLOCKERS = 0 is necessary but not by itself
 *   sufficient; evidence coverage is required"), the evidence is not
 *   stale, and a Tier-1 hash exists to prove — any other state, any
 *   blocker, incomplete coverage, an open finding, stale evidence or a
 *   missing hash disables the button and surfaces the reason;
 * * the canvas never offers a LOCK the control plane would answer
 *   ``400 LOCK_DENIED``: the server gate checks exactly evidence
 *   coverage, blockers and open red-team findings, so the bar mirrors
 *   those conditions instead of trusting ``blocker_count = 0`` alone;
 * * PAUSE is offered only to a BUILDING run and RESUME only to a
 *   PAUSED run, mirroring the control-plane transitions
 *   (``LIFECYCLE_STATES`` / ``kcc_autobuild.api``).
 *
 * The bar is stateless concerning retries: after a
 * ``StaleProjectionError`` the App refetches the projections and
 * re-renders this bar from the fresh surface, and the user presses
 * LOCK again explicitly — the bar never auto-retries a command.
 */
import type { LifecycleState, ReadinessProjection } from "../types";

/** The state in which the final LOCK & BUILD command is accepted. */
export const LOCK_EXPECTED_STATE: LifecycleState = "CONTRACT_REVIEW";

/** The state a run must be in for PAUSE. */
export const PAUSE_EXPECTED_STATE: LifecycleState = "BUILDING";

/** The state a run must be in for RESUME. */
export const RESUME_EXPECTED_STATE: LifecycleState = "PAUSED";

/** Visible label of the final pre-build authorization button. */
export const LOCK_BUTTON_LABEL = "LOCK & BUILD";

/** Verdict of the LOCK gate, with every blocking reason spelled out. */
export interface LockGate {
  enabled: boolean;
  reasons: string[];
}

export const READINESS_NOT_LOADED_REASON = "readiness not loaded";
export const STALE_EVIDENCE_REASON = "readiness evidence is stale";
/** Spec 13.1: blockers = 0 is necessary, evidence coverage is required. */
export const COVERAGE_INCOMPLETE_REASON =
  "readiness evidence coverage is incomplete";
/** The server verdict is authoritative: a NOT READY verdict closes LOCK. */
export const NOT_READY_REASON =
  "readiness verdict is NOT READY (evidence coverage required before LOCK)";
export const MISSING_TIER1_HASH_REASON = "contract Tier-1 hash unavailable";

/**
 * The LOCK gate: enable exactly when the run is in CONTRACT_REVIEW,
 * the readiness projection is a READY verdict with no blockers, no
 * open red-team findings and no stale evidence (the server-side
 * ``lock_contract`` gate conditions), and a Tier-1 hash exists to
 * prove.
 */
export function lockGate(
  state: LifecycleState,
  readiness: ReadinessProjection | null,
  tier1Hash: string | null,
): LockGate {
  const reasons: string[] = [];
  if (state !== LOCK_EXPECTED_STATE) {
    reasons.push(`LOCK expects CONTRACT_REVIEW (current: ${state})`);
  }
  if (readiness === null) {
    reasons.push(READINESS_NOT_LOADED_REASON);
  } else {
    if (!readiness.ready) {
      reasons.push(NOT_READY_REASON);
    }
    if (!readiness.coverage_ok) {
      reasons.push(COVERAGE_INCOMPLETE_REASON);
    }
    if (readiness.blockers.length > 0) {
      reasons.push(
        `${readiness.blockers.length} blocker(s) unresolved: ${readiness.blockers.join(", ")}`,
      );
    }
    if (readiness.open_red_team_findings.length > 0) {
      reasons.push(
        `${readiness.open_red_team_findings.length} open red-team finding(s): ${readiness.open_red_team_findings.join(", ")}`,
      );
    }
    if (readiness.evidence_stale) {
      reasons.push(STALE_EVIDENCE_REASON);
    }
  }
  if (tier1Hash === null) {
    reasons.push(MISSING_TIER1_HASH_REASON);
  }
  return { enabled: reasons.length === 0, reasons };
}

/** PAUSE is offered only to a BUILDING run (mirrors the control plane). */
export function pauseEnabled(state: LifecycleState): boolean {
  return state === PAUSE_EXPECTED_STATE;
}

/** RESUME is offered only to a PAUSED run (mirrors the control plane). */
export function resumeEnabled(state: LifecycleState): boolean {
  return state === RESUME_EXPECTED_STATE;
}

export interface LockBarProps {
  state: LifecycleState;
  readiness: ReadinessProjection | null;
  tier1Hash: string | null;
  busy: boolean;
  error: string | null;
  /** True after a stale projection refresh: the surface must be reviewed again. */
  staleRefreshed: boolean;
  onLock: (tier1Hash: string) => void;
  onPause: () => void;
  onResume: () => void;
}

export function LockBar(props: LockBarProps) {
  const gate = lockGate(props.state, props.readiness, props.tier1Hash);
  return (
    <section className="lock-bar" aria-label="LOCK & BUILD">
      <h2>LOCK &amp; BUILD</h2>
      {props.staleRefreshed ? (
        <p className="lock-bar__stale-notice">
          The command failed on a stale projection — run, readiness and contract
          were refreshed from the control plane. Review the Lock surface before
          locking again.
        </p>
      ) : null}
      {gate.reasons.length > 0 ? (
        <ul className="lock-bar__reasons">
          {gate.reasons.map((reason) => (
            <li key={reason} className="lock-bar__reason">
              {reason}
            </li>
          ))}
        </ul>
      ) : null}
      <div className="lock-bar__buttons">
        <button
          className="lock-bar__button"
          disabled={!gate.enabled || props.busy}
          onClick={() => {
            if (props.tier1Hash !== null) {
              props.onLock(props.tier1Hash);
            }
          }}
        >
          {LOCK_BUTTON_LABEL}
        </button>
        <button
          className="lock-bar__pause"
          disabled={!pauseEnabled(props.state) || props.busy}
          onClick={props.onPause}
        >
          PAUSE
        </button>
        <button
          className="lock-bar__resume"
          disabled={!resumeEnabled(props.state) || props.busy}
          onClick={props.onResume}
        >
          RESUME
        </button>
      </div>
      {props.error !== null ? (
        <p className="lock-bar__error" role="alert">
          {props.error}
        </p>
      ) : null}
    </section>
  );
}
