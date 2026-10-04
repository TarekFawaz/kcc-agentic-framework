import type { SolutionContext, Stack } from "./model";

const STACK_DIALECTS: Record<Stack, string[]> = {
  python: ["backend-python"],
  nodejs: ["backend-nodejs"],
  nestjs: ["backend-nodejs", "fullstack-nestjs"],
  mern: ["backend-nodejs", "fullstack-mern", "frontend-react"],
  react: ["frontend-react"],
  angular: ["frontend-angular"],
  "vanilla-js": ["frontend-vanilla-js"],
  dotnet: ["backend-csharp"],
  go: ["backend-go"],
  rust: ["backend-rust"],
  java: ["backend-java"],
  cpp: ["backend-cpp"],
  c: [],
  php: ["backend-php"],
};

const FULLSTACK: Partial<Record<Stack, string>> = { python: "fullstack-python", dotnet: "fullstack-dotnet", go: "fullstack-go" };
const EMBEDDED: Partial<Record<Stack, string>> = { c: "embedded-c", cpp: "embedded-cpp", rust: "embedded-rust" };

export interface TailoringPlan {
  /** Dialect file names (no extension) kept in the project. */
  dialects: string[];
  exclude_agents: string[];
  exclude_skills: string[];
  /** One line per decision, for the human. */
  reasons: string[];
}

/**
 * Deterministic mapping from the solution context to the capability set.
 * `available` is every dialect the framework ships; with no stack known,
 * no language dialect is pruned.
 */
export function planTailoring(ctx: SolutionContext, available: string[]): TailoringPlan {
  const reasons: string[] = [];
  const keep = new Set<string>(["testing-unit", "testing-integration", "testing-security"]);
  if (ctx.performance_tests) keep.add("testing-performance");
  else reasons.push("performance tests off -> testing-performance dialect dropped");

  if (ctx.dialects) {
    for (const d of ctx.dialects) keep.add(d);
    reasons.push(`dialects set explicitly: ${ctx.dialects.join(", ")}`);
  } else if (ctx.stacks.length === 0) {
    for (const d of available) if (!/^(devops|testing)-/.test(d)) keep.add(d);
    reasons.push("no stack given -> every language dialect kept");
  } else {
    for (const s of ctx.stacks) {
      if (ctx.project_type === "embedded" && EMBEDDED[s]) keep.add(EMBEDDED[s]);
      else for (const d of STACK_DIALECTS[s]) keep.add(d);
      if (ctx.has_ui && FULLSTACK[s]) keep.add(FULLSTACK[s]);
    }
    if (ctx.has_ui) keep.add("frontend-general");
    reasons.push(`stacks ${ctx.stacks.join(", ")} -> ${[...keep].filter((d) => !d.startsWith("testing-")).join(", ")}`);
  }

  if (ctx.deployment === "cloud" || ctx.deployment === "hybrid") keep.add("devops-cloud");
  if (ctx.deployment === "kubernetes" || ctx.deployment === "onprem" || ctx.deployment === "hybrid") keep.add("devops-k8s-onprem-agnostic");

  const exclude_agents: string[] = [];
  const exclude_skills: string[] = [];
  if (!ctx.has_ui) {
    exclude_agents.push("ux-ui-designer");
    exclude_skills.push("ux-ui-interrogator");
    reasons.push("no user interface -> UX/UI designer and interrogator dropped");
  }
  if (ctx.deployment === "none") {
    exclude_agents.push("infrastructure-planner", "infrastructure-implementer");
    exclude_skills.push("infrastructure-interrogator", "spec-deploy");
    reasons.push("nothing is deployed -> infrastructure agents, /spec-deploy, and devops dialects dropped");
  }
  if (!ctx.existing_codebase) {
    exclude_agents.push("solution-cartographer", "solution-inspector");
    exclude_skills.push("solution-onboard");
    reasons.push("greenfield -> solution onboarding agents dropped");
  }
  if (!ctx.import_workflows) {
    exclude_agents.push("migrator");
    exclude_skills.push("adapt-workflow");
    reasons.push("no external workflow to import -> migrator dropped");
  }

  return { dialects: available.filter((d) => keep.has(d)), exclude_agents, exclude_skills, reasons };
}
