/**
 * Tests that :file:`src/types.ts` exactly mirrors the canonical enum
 * members of the control-plane runtime (KCC x Superpowers Hybrid
 * Framework Plan 06, Task 2).
 *
 * The canonical enum ``AUTO_PROVISION_AUTHORIZED`` must never be
 * renamed (plan Global Constraint), so it is asserted by value here in
 * addition to belonging to the dependency-status set.
 */
import { describe, expect, it } from "vitest";

import {
  DEPENDENCY_STATUSES,
  DESTRUCTIVE_ACTIONS,
  EVIDENCE_KINDS,
  EVIDENCE_RESULTS,
  LIFECYCLE_STATES,
  NODE_KINDS,
  READINESS_STATUSES,
  RED_TEAM_DISPOSITIONS,
  ROLLOUT_CLASSES,
} from "./types";

describe("types.ts mirrors the runtime canonical enums", () => {
  it("mirrors kcc_autobuild.models.LifecycleState exactly", () => {
    expect(LIFECYCLE_STATES).toEqual([
      "INTAKE",
      "DISCOVERY",
      "PROTOTYPE_REVIEW",
      "ARCHITECTURE",
      "DE_RISK",
      "READINESS",
      "CONTRACT_REVIEW",
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
    ]);
  });

  it("mirrors DependencyStatus exactly and keeps AUTO_PROVISION_AUTHORIZED canonical", () => {
    expect(DEPENDENCY_STATUSES).toEqual([
      "USER_MUST_PROVIDE",
      "ALREADY_EXISTS",
      "AUTO_PROVISION_AUTHORIZED",
      "NOT_REQUIRED",
    ]);
    expect(DEPENDENCY_STATUSES).toContain("AUTO_PROVISION_AUTHORIZED");
  });

  it("mirrors ReadinessStatus exactly", () => {
    expect(READINESS_STATUSES).toEqual([
      "BLOCKER",
      "RISK_MITIGATED",
      "ACCEPTED_RISK",
      "READY",
    ]);
  });

  it("mirrors the readiness evidence kinds and results exactly", () => {
    expect(EVIDENCE_KINDS).toEqual(["identity", "permissions", "quota", "smoke_probe"]);
    expect(EVIDENCE_RESULTS).toEqual(["pass", "fail", "unknown"]);
  });

  it("mirrors the trace node kinds exactly", () => {
    expect(NODE_KINDS).toEqual([
      "requirement",
      "journey",
      "flow",
      "screen",
      "component",
      "api",
      "data",
      "dependency",
      "implementation",
      "acceptance",
      "test",
      "observability",
      "production_validation",
    ]);
  });

  it("mirrors the red-team dispositions exactly", () => {
    expect(RED_TEAM_DISPOSITIONS).toEqual([
      "OPEN",
      "RESOLVED",
      "MITIGATED",
      "ACCEPTED",
    ]);
  });

  it("mirrors the destructive action classes and rollout classes exactly", () => {
    expect(DESTRUCTIVE_ACTIONS).toEqual([
      "REVERSIBLE_AUTONOMOUS",
      "REVERSIBLE_WITH_ROLLBACK_REQUIRED",
      "IRREVERSIBLE_WHITELISTED",
      "IRREVERSIBLE_NOT_AUTHORIZED",
    ]);
    expect(ROLLOUT_CLASSES).toEqual(["CANARY", "DIRECT"]);
  });
});
