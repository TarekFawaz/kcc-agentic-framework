/**
 * Behavioral tests for the build-contract surface (KCC x Superpowers
 * Hybrid Framework Plan 06, Task 4; Design Spec v1.2 sections 14
 * "The Build Contract" and 15 "Final LOCK Experience").
 *
 * Written first (strict TDD red phase), against the external behavior
 * contract of :file:`src/components/ContractPanel.tsx`:
 *
 * * an absent contract renders a clear empty state (discovery is still
 *   open);
 * * a present contract renders the contract version, the canonical
 *   Tier-1 hash (the value the canvas proves at LOCK), the Tier-1
 *   product scope and Definition of Done;
 * * the canonical ``AUTO_PROVISION_AUTHORIZED`` authority enum value
 *   is rendered verbatim, never renamed (plan Global Constraint).
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { ContractProjection } from "../types";
import { ContractPanel } from "./ContractPanel";

const TIER1_HASH = "a".repeat(64);

const CONTRACT: ContractProjection = {
  present: true,
  contract_version: "1.0",
  tier1_hash: TIER1_HASH,
  tier1: {
    product_scope: "Canvas readiness and lock review surface",
    non_goals: ["no automatic deployment"],
    primary_user_journeys: [
      "Review readiness evidence",
      "Approve LOCK & BUILD",
    ],
    ux_direction: null,
    prototype_ref: "https://preview.example.test/prototype/run-042/",
    provider_whitelist: [{ provider: "example-provider", paid: false }],
    fallback_whitelist: [],
    auth_model: null,
    core_data_entities: ["run", "readiness", "contract"],
    security_constraints: [],
    authority: {
      auto_provision_status: "AUTO_PROVISION_AUTHORIZED",
      auto_provision_providers: ["example-provider"],
      approved_accounts: ["acct-042"],
      credential_refs: ["env://EXAMPLE_TOKEN"],
      dependency_installation: true,
      environment_creation: false,
      cicd_configuration: false,
      database_migration: false,
      dns_changes: false,
      approved_dns_zones: [],
      staging_deployment: false,
      production_deployment: false,
      rollback: false,
      monitoring_setup: false,
      secret_reference_usage: true,
      bounded_spend: true,
      auto_debug: false,
    },
    money: {
      hard_limits: true,
      currency: "USD",
      one_time_build_budget: null,
      per_provider_caps: { "example-provider": 5000 },
      monthly_infrastructure_cap: null,
      model_token_cap: null,
    },
    destructive_policy: [],
    production_target: null,
    rollout_class: null,
    definition_of_done:
      "A fresh lock surface is displayed after a stale projection; LOCK is never auto-retried.",
    definition_of_done_ids: ["AC-042-1"],
    requires_rollback_evidence: false,
  },
  tier2: null,
  trace: null,
  readiness: null,
  resume: null,
  locked_at: null,
  contract_hash: null,
  tier2_hash: null,
};

describe("ContractPanel absent contract", () => {
  /** The full absent-contract projection the control plane serializes. */
  const ABSENT: ContractProjection = {
    present: false,
    contract_version: "1.0",
    tier1_hash: null,
    tier1: null,
    tier2: null,
    trace: null,
    readiness: null,
    resume: null,
    locked_at: null,
    contract_hash: null,
    tier2_hash: null,
  };

  it("renders an empty state and no hash when discovery has no contract yet", () => {
    const html = renderToStaticMarkup(<ContractPanel contract={ABSENT} />);
    expect(html).toContain("contract-panel__empty");
    expect(html).not.toContain(TIER1_HASH);
  });
});

describe("ContractPanel present contract", () => {
  const html = renderToStaticMarkup(<ContractPanel contract={CONTRACT} />);

  it("renders the contract version", () => {
    expect(html).toContain("1.0");
  });

  it("renders the canonical Tier-1 hash the canvas proves at LOCK", () => {
    expect(html).toContain(TIER1_HASH);
    expect(html).toContain("contract-panel__tier1-hash");
  });

  it("renders the Tier-1 product scope and Definition of Done", () => {
    expect(html).toContain("Canvas readiness and lock review surface");
    expect(html).toContain(
      "A fresh lock surface is displayed after a stale projection",
    );
  });

  it("renders every primary user journey", () => {
    expect(html).toContain("Review readiness evidence");
    expect(html).toContain("Approve LOCK &amp; BUILD");
  });

  it("renders the canonical AUTO_PROVISION_AUTHORIZED authority enum verbatim", () => {
    expect(html).toContain("AUTO_PROVISION_AUTHORIZED");
  });

  it("renders credential references only (never a raw secret value)", () => {
    expect(html).toContain("env://EXAMPLE_TOKEN");
    expect(html).not.toContain("sk-");
  });
});
