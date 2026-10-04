export const PROJECT_TYPES = ["web-app", "api-service", "cli-tool", "library", "mobile", "embedded", "data-pipeline", "other"] as const;
export const DEPLOYMENTS = ["none", "cloud", "kubernetes", "onprem", "hybrid"] as const;
export const SENSITIVITIES = ["low", "medium", "high"] as const;
export const STACKS = ["python", "nodejs", "nestjs", "mern", "react", "angular", "vanilla-js", "dotnet", "go", "rust", "java", "cpp", "c", "php"] as const;

export type ProjectType = (typeof PROJECT_TYPES)[number];
export type Deployment = (typeof DEPLOYMENTS)[number];
export type Sensitivity = (typeof SENSITIVITIES)[number];
export type Stack = (typeof STACKS)[number];

/** What a human tells KCC about the solution it will be used on. */
export interface SolutionContext {
  name: string;
  project_type: ProjectType;
  stacks: Stack[];
  has_ui: boolean;
  deployment: Deployment;
  existing_codebase: boolean;
  import_workflows: boolean;
  data_sensitivity: Sensitivity;
  performance_tests: boolean;
  coverage_min_pct: number | null;
  /** Explicit dialect list; overrides the stack mapping when set. */
  dialects: string[] | null;
}

export function defaultContext(): SolutionContext {
  return {
    name: "",
    project_type: "other",
    stacks: [],
    has_ui: true,
    deployment: "cloud",
    existing_codebase: false,
    import_workflows: false,
    data_sensitivity: "medium",
    performance_tests: true,
    coverage_min_pct: null,
    dialects: null,
  };
}

const STACK_ALIASES: Record<string, Stack> = {
  py: "python", node: "nodejs", "node.js": "nodejs", javascript: "nodejs", typescript: "nodejs", js: "nodejs", ts: "nodejs",
  nest: "nestjs", "c#": "dotnet", csharp: "dotnet", ".net": "dotnet", golang: "go", "c++": "cpp", vanilla: "vanilla-js",
};

function asBool(v: unknown): boolean | undefined {
  if (typeof v === "boolean") return v;
  if (typeof v === "string") {
    if (/^(y|yes|true|1)$/i.test(v.trim())) return true;
    if (/^(n|no|false|0)$/i.test(v.trim())) return false;
  }
  return undefined;
}

function asList(v: unknown): string[] | undefined {
  if (Array.isArray(v)) return v.map((x) => String(x).trim()).filter(Boolean);
  if (typeof v === "string") return v.split(/[,;]/).map((x) => x.trim()).filter(Boolean);
  return undefined;
}

export function normalizeStacks(list: string[]): Stack[] {
  const out: Stack[] = [];
  for (const raw of list) {
    const k = raw.toLowerCase();
    const s = (STACK_ALIASES[k] ?? k) as Stack;
    if ((STACKS as readonly string[]).includes(s) && !out.includes(s)) out.push(s);
  }
  return out;
}

/** Applies the known keys of `input` onto `base`. Returns the problems found; unknown keys are ignored. */
export function mergeContext(base: SolutionContext, input: Record<string, unknown>): string[] {
  const problems: string[] = [];
  const pick = <T extends string>(key: string, allowed: readonly T[]): T | undefined => {
    const v = input[key];
    if (v === undefined || v === null || v === "") return undefined;
    const s = String(v).trim().toLowerCase() as T;
    if (allowed.includes(s)) return s;
    problems.push(`${key}: '${String(v)}' is not one of ${allowed.join(", ")}`);
    return undefined;
  };
  if (typeof input.name === "string") base.name = input.name.trim();
  base.project_type = pick("project_type", PROJECT_TYPES) ?? base.project_type;
  base.deployment = pick("deployment", DEPLOYMENTS) ?? base.deployment;
  base.data_sensitivity = pick("data_sensitivity", SENSITIVITIES) ?? base.data_sensitivity;
  const stacks = asList(input.stacks ?? input.stack);
  if (stacks) {
    base.stacks = normalizeStacks(stacks);
    const unknown = stacks.filter((s) => normalizeStacks([s]).length === 0);
    if (unknown.length) problems.push(`stacks: unknown ${unknown.join(", ")} (known: ${STACKS.join(", ")})`);
  }
  for (const key of ["has_ui", "existing_codebase", "import_workflows", "performance_tests"] as const) {
    if (input[key] === undefined) continue;
    const b = asBool(input[key]);
    if (b === undefined) problems.push(`${key}: expected true or false`);
    else base[key] = b;
  }
  if (input.coverage_min_pct !== undefined && input.coverage_min_pct !== null && input.coverage_min_pct !== "") {
    const n = Number(input.coverage_min_pct);
    if (Number.isFinite(n) && n >= 0 && n <= 100) base.coverage_min_pct = n;
    else problems.push("coverage_min_pct: expected a number from 0 to 100");
  }
  const dialects = asList(input.dialects);
  if (dialects) base.dialects = dialects.length ? dialects : null;
  return problems;
}
