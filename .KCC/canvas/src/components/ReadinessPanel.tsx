/**
 * Readiness surface for the autobuild canvas.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 4 (Design Spec v1.2
 * sections 12-13 "Readiness" and section 15 "Final LOCK Experience"):
 * the panel mirrors the server's evidence-backed readiness evaluation.
 * The verdict is the control-plane verdict (``ready``) — the canvas
 * never re-derives it — and the inputs of the LOCK gate are visible:
 * unresolved blockers, open red-team findings and the stale-evidence
 * state.  Each readiness item renders its server status and whether
 * its evidence is current.
 */
import type { ReadinessProjection } from "../types";

export function ReadinessPanel({ readiness }: { readiness: ReadinessProjection }) {
  return (
    <section className="readiness-panel" aria-label="Readiness">
      <h2>Readiness</h2>
      <p
        className="readiness-panel__verdict"
        data-ready={readiness.ready ? "true" : "false"}
      >
        {readiness.ready ? "READY" : "NOT READY"}
      </p>
      <p
        className="readiness-panel__coverage"
        data-coverage-ok={readiness.coverage_ok ? "true" : "false"}
      >
        evidence coverage {readiness.coverage_ok ? "complete" : "incomplete"}
      </p>
      {readiness.evidence_stale ? (
        <p className="readiness-panel__stale">
          readiness evidence is stale — refresh before LOCK
        </p>
      ) : null}
      <p className="readiness-panel__blocker-count">
        {readiness.blockers.length} blocker(s)
      </p>
      {readiness.blockers.length > 0 ? (
        <ul className="readiness-panel__blocker-list">
          {readiness.blockers.map((id) => (
            <li key={id} className="readiness-panel__blocker">
              {id}
            </li>
          ))}
        </ul>
      ) : null}
      {readiness.open_red_team_findings.length > 0 ? (
        <ul className="readiness-panel__finding-list">
          {readiness.open_red_team_findings.map((id) => (
            <li key={id} className="readiness-panel__finding">
              {id}
            </li>
          ))}
        </ul>
      ) : null}
      <ul className="readiness-panel__items">
        {readiness.items.map((item) => (
          <li
            key={item.item_id}
            className="readiness-panel__item"
            data-status={item.status}
            data-evidence-current={item.evidence_current ? "true" : "false"}
          >
            {item.item_id} — {item.status}
          </li>
        ))}
      </ul>
    </section>
  );
}
