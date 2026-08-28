/**
 * Type mirror of the autobuild discovery control-plane projections.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 2: this module
 * exactly mirrors the lifecycle / run / trace / readiness / contract
 * projection types of the control-plane API
 * (``.KCC/runtime/src/kcc_autobuild/api.py`` and its
 * :mod:`models` / :mod:`trace` / :mod:`readiness` / :mod:`contract`
 * sources).
 *
 * Mirror rules:
 *
 * * enum/string unions are declared from ``as const`` member arrays so
 *   the canonical member sets are runtime-verifiable (the canonical
 *   ``AUTO_PROVISION_AUTHORIZED`` is never renamed);
 * * every ``Optional[...]`` / ``| None`` pydantic field is mirrored as a
 *   required property typed ``X | null`` — the API serializes JSON with
 *   explicit ``null`` (``model_dump(mode="json")`` does not omit none
 *   values), never an absent key;
 * * datetimes / timedeltas arrive as JSON strings (ISO-8601).
 */

export const LIFECYCLE_STATES = [
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
] as const;

/** kcc_autobuild.models.LifecycleState */
export type LifecycleState = (typeof LIFECYCLE_STATES)[number];

export const DEPENDENCY_STATUSES = [
  "USER_MUST_PROVIDE",
  "ALREADY_EXISTS",
  "AUTO_PROVISION_AUTHORIZED",
  "NOT_REQUIRED",
] as const;

/** kcc_autobuild.models.DependencyStatus (canonical, never renamed) */
export type DependencyStatus = (typeof DEPENDENCY_STATUSES)[number];

export const READINESS_STATUSES = [
  "BLOCKER",
  "RISK_MITIGATED",
  "ACCEPTED_RISK",
  "READY",
] as const;

/** kcc_autobuild.models.ReadinessStatus */
export type ReadinessStatus = (typeof READINESS_STATUSES)[number];

export const EVIDENCE_KINDS = [
  "identity",
  "permissions",
  "quota",
  "smoke_probe",
] as const;

/** kcc_autobuild.providers.base.EvidenceKind */
export type EvidenceKind = (typeof EVIDENCE_KINDS)[number];

export const EVIDENCE_RESULTS = ["pass", "fail", "unknown"] as const;

/** kcc_autobuild.providers.base.EvidenceResult */
export type EvidenceResult = (typeof EVIDENCE_RESULTS)[number];

export const NODE_KINDS = [
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
] as const;

/** kcc_autobuild.trace.NodeKind */
export type NodeKind = (typeof NODE_KINDS)[number];

export const RED_TEAM_DISPOSITIONS = [
  "OPEN",
  "RESOLVED",
  "MITIGATED",
  "ACCEPTED",
] as const;

/** kcc_autobuild.readiness.RedTeamDisposition */
export type RedTeamDisposition = (typeof RED_TEAM_DISPOSITIONS)[number];

export const DESTRUCTIVE_ACTIONS = [
  "REVERSIBLE_AUTONOMOUS",
  "REVERSIBLE_WITH_ROLLBACK_REQUIRED",
  "IRREVERSIBLE_WHITELISTED",
  "IRREVERSIBLE_NOT_AUTHORIZED",
] as const;

/** kcc_autobuild.contract.DestructiveAction */
export type DestructiveAction = (typeof DESTRUCTIVE_ACTIONS)[number];

export const ROLLOUT_CLASSES = ["CANARY", "DIRECT"] as const;

/** kcc_autobuild.contract.RolloutClass */
export type RolloutClass = (typeof ROLLOUT_CLASSES)[number];

// ---------------------------------------------------------------------------
// Run projection (kcc_autobuild.api.RunProjection over RunRecord)
// ---------------------------------------------------------------------------

export interface RunProjection {
  run_id: string;
  title: string;
  /** ``created_at`` serialized as ISO-8601 UTC. */
  created_at: string;
  state: LifecycleState;
  contract_hash: string | null;
}

// ---------------------------------------------------------------------------
// Trace projection (kcc_autobuild.api.TraceProjection over TraceGraph)
// ---------------------------------------------------------------------------

export interface TraceNode {
  id: string;
  kind: NodeKind;
}

export interface TraceEdge {
  source: string;
  target: string;
}

export interface TraceGraph {
  run_id: string | null;
  nodes: TraceNode[];
  edges: TraceEdge[];
}

export interface TraceCoverageResult {
  covered: string[];
  orphans: string[];
}

export interface TraceProjection {
  run_id: string | null;
  nodes: TraceNode[];
  edges: TraceEdge[];
  coverage: TraceCoverageResult;
}

// ---------------------------------------------------------------------------
// Readiness projection (kcc_autobuild.api.ReadinessProjection over
// ReadinessPack / ReadinessItem / EvidenceRecord / FallbackEntry)
// ---------------------------------------------------------------------------

export interface EvidenceRecord {
  kind: EvidenceKind;
  /** ``checked_at`` serialized as ISO-8601 UTC. */
  checked_at: string;
  result: EvidenceResult;
  principal: string | null;
  resource_ids: string[];
  scopes: string[];
  mode: string | null;
  quota: string | null;
  shared_account: boolean;
}

export interface RedTeamFinding {
  id: string;
  summary: string;
  disposition: RedTeamDisposition;
  related_item_id: string | null;
}

export interface FallbackEntry {
  provider: string;
  trigger_scope: string;
  allowed_function: string;
  data_classes_allowed: string[];
  regions_allowed: string[];
  /** Secret reference only (vault://, env:// or keychain://). */
  credential_ref: string;
  switch_revalidation_required: boolean;
}

export interface ReadinessItem {
  id: string;
  provider: string;
  status: ReadinessStatus;
  required_kinds: EvidenceKind[];
  evidence: EvidenceRecord[];
  fallbacks: FallbackEntry[];
  /** ``evidence_ttl`` serialized as an ISO-8601 duration. */
  evidence_ttl: string;
}

export interface ReadinessPack {
  items: ReadinessItem[];
  red_team_findings: RedTeamFinding[];
}

export interface ReadinessItemProjection {
  item_id: string;
  status: ReadinessStatus;
  reasons: string[];
  evidence: EvidenceRecord[];
  fallbacks: FallbackEntry[];
  evidence_current: boolean;
}

export interface ReadinessProjection {
  ready: boolean;
  coverage_ok: boolean;
  blockers: string[];
  open_red_team_findings: string[];
  evidence_stale: boolean;
  items: ReadinessItemProjection[];
}

// ---------------------------------------------------------------------------
// Contract projection (kcc_autobuild.api.ContractProjection over the
// two-tier BuildContract: Tier1Invariants / Tier2Details / ResumeProtocol)
// ---------------------------------------------------------------------------

export interface ProviderEntry {
  provider: string;
  paid: boolean;
}

export interface AuthorityEnvelope {
  auto_provision_status: DependencyStatus;
  auto_provision_providers: string[];
  approved_accounts: string[];
  /** Secret references only. */
  credential_refs: string[];
  dependency_installation: boolean;
  environment_creation: boolean;
  cicd_configuration: boolean;
  database_migration: boolean;
  dns_changes: boolean;
  approved_dns_zones: string[];
  staging_deployment: boolean;
  production_deployment: boolean;
  rollback: boolean;
  monitoring_setup: boolean;
  secret_reference_usage: boolean;
  bounded_spend: boolean;
  auto_debug: boolean;
}

export interface MoneyPolicy {
  hard_limits: boolean;
  currency: string;
  one_time_build_budget: number | null;
  /** Provider spend caps in minor units. */
  per_provider_caps: Record<string, number>;
  monthly_infrastructure_cap: number | null;
  model_token_cap: number | null;
}

export interface DestructiveOperationRule {
  operation: string;
  classification: DestructiveAction;
  rollback_path: string | null;
  backup_required: boolean;
}

export interface Tier2Details {
  component_boundaries: string[];
  internal_api_shapes: string[];
  helper_libraries: string[];
  db_indexes: string[];
  error_wording: string | null;
  internal_refactors: string[];
  test_organization: string[];
  minor_dependency_changes: string[];
  observability_thresholds: string[];
  css_layout_detail: string | null;
  staging_provider: string | null;
}

export interface ResumeProtocol {
  lifecycle_state: LifecycleState | null;
  current_task: string | null;
  completed_task_commits: string[];
  test_results: string[];
  review_state: string | null;
  outstanding_findings: string[];
  attempt_counters: Record<string, number>;
  spend_so_far: Record<string, number>;
  deviations: string[];
  contract_version: string | null;
}

export interface Tier1Invariants {
  product_scope: string;
  non_goals: string[];
  primary_user_journeys: string[];
  ux_direction: string | null;
  prototype_ref: string | null;
  provider_whitelist: ProviderEntry[];
  fallback_whitelist: string[];
  auth_model: string | null;
  core_data_entities: string[];
  security_constraints: string[];
  authority: AuthorityEnvelope;
  money: MoneyPolicy;
  destructive_policy: DestructiveOperationRule[];
  production_target: string | null;
  rollout_class: RolloutClass | null;
  definition_of_done: string;
  definition_of_done_ids: string[];
  requires_rollback_evidence: boolean;
}

export interface ContractProjection {
  present: boolean;
  contract_version: string;
  /** Canonical Tier-1 hash — the value the canvas proves at LOCK. */
  tier1_hash: string | null;
  tier1: Tier1Invariants | null;
  tier2: Tier2Details | null;
  trace: TraceGraph | null;
  readiness: ReadinessPack | null;
  resume: ResumeProtocol | null;
  /** ``locked_at`` serialized as ISO-8601 UTC. */
  locked_at: string | null;
  contract_hash: string | null;
  tier2_hash: string | null;
}

// ---------------------------------------------------------------------------
// Commands (kcc_autobuild.api.CommandRequest / LockRequest / CommandResult)
// ---------------------------------------------------------------------------

/** Every canvas command carries the expected run state. */
export interface CommandRequest {
  expected_state: LifecycleState;
}

/** LOCK & BUILD proves the projection it approved (canonical Tier-1 hash). */
export interface LockRequest extends CommandRequest {
  tier1_hash: string;
}

export interface CommandResult {
  command: string;
  accepted: boolean;
  run: RunProjection;
}

/** Error payload of the control-plane API (always ``{error, detail}``). */
export interface ApiErrorPayload {
  error: string;
  detail: string;
}
