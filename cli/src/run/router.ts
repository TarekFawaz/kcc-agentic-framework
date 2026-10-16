import { readFileSync } from "node:fs";
import { join } from "node:path";
import { readJson } from "../fsutil";

/**
 * Model router (kernel/protocols/model-routing.md): moves an agent's default tier by at most one step
 * and sets the effort from the signals a run has. Pure, so it is tested as a table.
 */
export type Tier = "strong" | "balanced" | "fast";
export type Effort = "low" | "medium" | "high" | "xhigh" | "max";
export type Task = "research" | "architecture" | "security" | "spec" | "plan" | "review" | "implement" | "scaffold" | "docs" | "close" | "other";
export type Domain = "common" | "specialised" | "novel";

export interface RouteInput {
  defaultTier: Tier;
  defaultEffort: Effort;
  task: Task;
  domain?: Domain;
  risk?: boolean;
  complexity?: "low" | "medium" | "high" | "extra-high";
  items?: number;
  files?: number;
  attempt?: number;
  budgetLeftPct?: number;
}
export interface Route {
  tier: Tier;
  effort: Effort;
  reasons: string[];
}

const TIERS: Tier[] = ["fast", "balanced", "strong"];
const EFFORTS: Effort[] = ["low", "medium", "high", "xhigh", "max"];
const up = (t: Tier, max: Tier): Tier => TIERS[Math.min(TIERS.indexOf(t) + 1, TIERS.indexOf(max))]!;
const down = (t: Tier, min: Tier): Tier => TIERS[Math.max(TIERS.indexOf(t) - 1, TIERS.indexOf(min))]!;
const atLeast = (t: Tier, floor: Tier): Tier => (TIERS.indexOf(t) < TIERS.indexOf(floor) ? floor : t);
const atMost = (t: Tier, cap: Tier): Tier => (TIERS.indexOf(t) > TIERS.indexOf(cap) ? cap : t);
const effUp = (e: Effort): Effort => EFFORTS[Math.min(EFFORTS.indexOf(e) + 1, EFFORTS.indexOf("xhigh"))]!;
const effAtLeast = (e: Effort, f: Effort): Effort => (EFFORTS.indexOf(e) < EFFORTS.indexOf(f) ? f : e);

export function route(i: RouteInput): Route {
  const minTier = down(i.defaultTier, "fast");
  const maxTier = up(i.defaultTier, "strong");
  let tier = i.defaultTier;
  let effort: Effort = i.defaultEffort === "max" ? "xhigh" : i.defaultEffort;
  const reasons: string[] = [];
  const risk = !!i.risk || i.complexity === "high" || i.complexity === "extra-high";
  if (["research", "architecture", "security"].includes(i.task) && TIERS.indexOf(tier) < 1) { tier = "balanced"; reasons.push(`${i.task} never runs below balanced`); }
  if (i.domain === "novel") { tier = up(tier, maxTier); effort = effAtLeast(effort, "high"); reasons.push("novel domain"); }
  else if (i.domain === "common" && ["spec", "plan", "docs", "scaffold"].includes(i.task)) { tier = down(tier, minTier); reasons.push(`common domain, ${i.task}`); }
  if (risk) { tier = atLeast(tier, "balanced"); effort = effAtLeast(effort, "high"); reasons.push(i.risk ? "CR-7 risk" : `complexity ${i.complexity}`); }
  if ((i.items ?? 0) > 3 || (i.files ?? 0) > 5) { effort = effUp(effort); reasons.push("large unit"); }
  if ((i.attempt ?? 1) >= 2) { tier = up(tier, maxTier); effort = effUp(effort); reasons.push(`attempt ${i.attempt}`); }
  if (i.budgetLeftPct !== undefined && i.budgetLeftPct < 20 && !risk) { tier = atMost(tier, "balanced"); reasons.push("budget under 20%"); }
  tier = atMost(atLeast(tier, minTier), maxTier);
  return { tier, effort, reasons };
}

export interface Registry {
  version: string;
  verified: string;
  class_to_tier: Record<string, Tier>;
  deep_tasks?: string[];
  harnesses: Record<string, Record<string, { id: string; alias?: string; auto_mode?: boolean; max_effort?: string }>>;
}

/**
 * DeepThinking (kernel/protocols/deep-thinking.md). The `deep` tier is not a router output: `route()` never returns it.
 * A deep spawn is a closed list of tasks, each owned by one agent, and needs a human who has seen the cost.
 */
export const DEEP_TASKS: Record<string, string> = {
  "architecture-tradeoff": "architect",
  "threat-model": "security-analyst",
  "failure-root-cause": "verifier",
  "cross-spec-consistency": "architect",
  /** Only a human can start this one (`/deep`): any bounded analysis the human names, run by the agent they pick. */
  "human-directed": "*",
};

export interface DeepRequest {
  task: string;
  agent: string;
  harness: string;
  registry: Registry;
  enabled?: boolean;
  approvedSoFar?: number;
  maxPerRun?: number;
  /** Who starts it: the orchestrator during `auto` (also under --fasttrack), or the human with `/deep`. Default orchestrator. */
  initiator?: "orchestrator" | "human";
  silent?: boolean;
  budgetLeftPct?: number;
  estUsdHigh?: number;
  preApprovedUsd?: number;
}
export interface DeepDecision {
  outcome: "ask" | "pre-approved" | "refuse";
  /** What runs instead when the outcome is `refuse` (or the human declines). */
  fallback: "strong" | "none";
  reason: string;
}

/** Order-of-magnitude cost of one deep spawn from the observed rates in models.json (a floor, not a quote). */
export function estimateDeepUsd(outputTokens: number, extraInputTokens = 0): number {
  return +(0.8 + outputTokens * 0.000048 + extraInputTokens * 0.00002).toFixed(2);
}

export function deepGate(r: DeepRequest): DeepDecision {
  const no = (reason: string): DeepDecision => ({ outcome: "refuse", fallback: "strong", reason });
  if (r.enabled === false) return no("deep.enabled is false");
  if (!r.registry.harnesses[r.harness]?.deep) return no(`harness ${r.harness} has no deep tier`);
  const owner = DEEP_TASKS[r.task];
  if (!owner) return no(`'${r.task}' is not a deep task`);
  const human = r.initiator === "human";
  // A human who types /deep is present and sees the cost every time, so the run-level limits (cap, budget, silent) do not apply to them.
  if (human) return { outcome: "ask", fallback: "none", reason: "the human asked for it; show the cost range and the effort choice" };
  if (owner === "*") return no(`${r.task} can only be started by the human (/deep)`);
  if (owner !== r.agent) return no(`${r.task} belongs to ${owner}, not ${r.agent}`);
  if ((r.approvedSoFar ?? 0) >= (r.maxPerRun ?? 2)) return no(`already ${r.approvedSoFar} deep spawns this run (max ${r.maxPerRun ?? 2})`);
  if (r.budgetLeftPct !== undefined && r.budgetLeftPct < 20) return no("budget under 20%");
  if (r.silent) {
    if ((r.preApprovedUsd ?? 0) > 0 && (r.estUsdHigh ?? Infinity) <= (r.preApprovedUsd ?? 0)) return { outcome: "pre-approved", fallback: "none", reason: `estimate within the pre-approved ${r.preApprovedUsd} USD` };
    return no("silent run and no pre-approved spend");
  }
  return { outcome: "ask", fallback: "strong", reason: "ask the human with the cost range" };
}

export function loadRegistry(root: string): Registry | undefined {
  return readJson<Registry>(join(root, ".KCC", "kernel", "models.json"));
}

/** The model id for a tier on a harness, from the registry. */
export function modelFor(reg: Registry, harness: string, tier: Tier): string | undefined {
  return reg.harnesses[harness]?.[tier]?.id;
}

/** `## Domain` of an idea's Research.md: common | specialised | novel. */
export function readDomain(root: string, ideaFolder: string): Domain | undefined {
  try {
    const t = readFileSync(join(root, "ideation", ideaFolder, "Research.md"), "utf8");
    const m = /##\s+Domain[^\n]*\n+\s*[-*]?\s*`?(common|specialised|specialized|novel)/i.exec(t) ?? /##\s+Domain\s*:\s*`?(common|specialised|specialized|novel)/i.exec(t);
    if (!m) return undefined;
    const v = m[1]!.toLowerCase();
    return v === "specialized" ? "specialised" : (v as Domain);
  } catch {
    return undefined;
  }
}
