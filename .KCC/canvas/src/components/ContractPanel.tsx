/**
 * Build-contract surface for the autobuild canvas.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 4 (Design Spec v1.2
 * sections 14 "The Build Contract" and 15 "Final LOCK Experience"):
 * the panel shows the two-tier Build Contract as the consolidated
 * approval surface — contract version, the canonical Tier-1 hash (the
 * value the canvas proves at LOCK), the Tier-1 product scope, the
 * primary user journeys, the Definition of Done and the authority
 * envelope of the approved autonomy.
 *
 * The canonical ``AUTO_PROVISION_AUTHORIZED`` authority enum value is
 * rendered verbatim (plan Global Constraint: never renamed), and
 * credential material is displayed as references only (the control
 * plane never publishes raw secrets; the canvas must never invent
 * any).
 */
import type { ContractProjection } from "../types";

export function ContractPanel({ contract }: { contract: ContractProjection }) {
  if (!contract.present || contract.tier1 === null) {
    return (
      <section className="contract-panel" aria-label="Build contract">
        <h2>Build Contract</h2>
        <p className="contract-panel__empty">
          No contract yet — the two-tier Build Contract is produced during
          discovery and reviewed here before LOCK.
        </p>
      </section>
    );
  }
  const tier1 = contract.tier1;
  return (
    <section className="contract-panel" aria-label="Build contract">
      <h2>Build Contract</h2>
      <dl className="contract-panel__summary">
        <dt>contract version</dt>
        <dd>{contract.contract_version}</dd>
        <dt>canonical Tier-1 hash</dt>
        <dd>
          <code className="contract-panel__tier1-hash">
            {contract.tier1_hash ?? "unavailable"}
          </code>
        </dd>
        <dt>product scope</dt>
        <dd>{tier1.product_scope}</dd>
        <dt>definition of done</dt>
        <dd>{tier1.definition_of_done}</dd>
        <dt>autonomy</dt>
        <dd data-authority-status={tier1.authority.auto_provision_status}>
          auto-provision {tier1.authority.auto_provision_status}
          {tier1.authority.bounded_spend ? ", spend bounded" : ", spend unbounded"}
        </dd>
      </dl>
      <ul className="contract-panel__journeys">
        {tier1.primary_user_journeys.map((journey) => (
          <li key={journey} className="contract-panel__journey">
            {journey}
          </li>
        ))}
      </ul>
      <p className="contract-panel__credentials">
        credential refs:{" "}
        {tier1.authority.credential_refs.length > 0
          ? tier1.authority.credential_refs.join(", ")
          : "none"}
      </p>
    </section>
  );
}
