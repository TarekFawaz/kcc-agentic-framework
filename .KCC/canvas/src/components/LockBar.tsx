/**
 * LOCK & BUILD surface for the autobuild canvas.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 4 (Design Spec v1.2
 * section 15 "Final LOCK Experience"; plan Global Constraints on
 * stale-state discipline).  LOCK & BUILD is the final formal pre-build
 * authorization, so the bar is gated strictly:
 *
 * * :func:`lockGate` enables LOCK only when the run state is exactly
 *   ``CONTRACT_REVIEW`` (LOCK is never offered outside the final
 *   review phase), the readiness projection has ZERO blockers
 *   (``blocker_count = 0``) and its evidence is not stale — any other
 *   state, any blocker or stale evidence disables the button and
 *   surfaces the reason;
 * * a missing Tier-1 contract hash disables LOCK too (the command
 *   must prove the hash; no hash means no request to send);
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
export const MISSING_TIER1_HASH_REASON = "contract Tier-1 hash unavailable";

/**
 * The LOCK gate: enable exactly when the run is in CONTRACT_REVIEW,
 * the readiness projection has no blockers and no stale evidence, and
 * a Tier-1 hash exists to prove.
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
    if (readiness.blockers.length > 0) {
      reasons.push(
        `${readiness.blockers.length} blocker(s) unresolved: ${readiness.blockers.join(", ")}`,
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
