import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { readJson } from "../fsutil";
import { readSettings } from "../settings";
import { loadRegistry, modelFor, readDomain, route, type Effort, type Tier } from "./router";

/**
 * Plan-time routing (kernel/protocols/model-routing.md). After the architect and the planner have said how complex
 * each backlog item is, this decides the model and the reasoning effort PER ITEM and writes them into plan.md as a
 * `## Routing` table. kcc-run and the orchestrator only read that table, so the rules live in one place (router.ts)
 * and the drivers stay plain scripts.
 */
export interface PlanItem {
  key: string;
  type: string;
  dialect: string;
  complexity: "low" | "medium" | "high" | "extra-high" | "";
  wave: string;
  notes: string;
}
export interface ItemRoute {
  key: string;
  wave: string;
  tier: Tier;
  model: string;
  effort: Effort;
  why: string;
}

const COMPLEXITIES = ["low", "medium", "high", "extra-high"];
/** Words that make an item security-sensitive (CR-7): auth, credentials, crypto, secrets, tokens, sessions, personal data. */
const SECURITY = /\b(auth(?:entication|orization|n|z)?|password|credential|crypto|secret|token|csrf|jwt|oauth|session|pii|personal data|payment|encrypt\w*)\b/i;

export function securityHit(text: string): string | undefined {
  return SECURITY.exec(text)?.[1]?.toLowerCase();
}

function cells(line: string): string[] {
  return line.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
}

/** The plan's Backlog Coverage table: Item | Type | Dialect | Complexity | Wave | ... | Notes. */
export function parsePlanItems(plan: string): PlanItem[] {
  const out: PlanItem[] = [];
  let hdr: string[] | undefined;
  for (const line of plan.replace(/\r\n/g, "\n").split("\n")) {
    if (!/^\s*\|/.test(line)) {
      if (hdr) break;
      continue;
    }
    const c = cells(line);
    if (!hdr) {
      const low = c.map((x) => x.toLowerCase());
      if (low.includes("item") && low.includes("complexity") && low.includes("wave")) hdr = low;
      continue;
    }
    if (/^[\s:|-]+$/.test(line)) continue;
    const at = (name: string): string => c[hdr!.indexOf(name)] ?? "";
    const cx = at("complexity").toLowerCase();
    out.push({
      key: at("item"),
      type: at("type"),
      dialect: at("dialect"),
      complexity: (COMPLEXITIES.includes(cx) ? cx : "") as PlanItem["complexity"],
      wave: at("wave"),
      notes: at("notes"),
    });
  }
  return out.filter((i) => i.key);
}

/** Impacted Files lines of a Backlog item file, and its title and acceptance criteria text for the security scan. */
function itemFacts(specDir: string, key: string): { files: number; text: string } {
  const dir = join(specDir, "Backlog");
  if (!existsSync(dir)) return { files: 0, text: "" };
  const f = readdirSync(dir).find((n) => n.toLowerCase().startsWith(key.toLowerCase() + "-") || n.toLowerCase() === key.toLowerCase() + ".md");
  if (!f) return { files: 0, text: "" };
  const t = readFileSync(join(dir, f), "utf8");
  const sec = /##\s+Impacted Files\s*\n([\s\S]*?)(?=\n##\s|$)/i.exec(t)?.[1] ?? "";
  const files = sec.split("\n").filter((l) => /^\s*[-*]\s+`/.test(l)).length;
  const head = t.split("\n").slice(0, 40).join("\n");
  return { files, text: head };
}

export interface RouteOptions {
  harness?: string;
  implementTier?: Tier;
  defaultEffort?: Effort;
  maxTier?: Tier;
}

/** One route per backlog item of a plan. */
export function routePlan(root: string, specDir: string, plan: string, o: RouteOptions = {}): ItemRoute[] {
  const reg = loadRegistry(root);
  const harness = o.harness ?? "claude";
  const idea = /IDEA-\d+[^/\\]*/.exec(specDir.replace(/\\/g, "/"))?.[0]?.replace(/-Specs$/, "");
  const domain = idea ? readDomain(root, idea) : undefined;
  return parsePlanItems(plan).map((it) => {
    const facts = itemFacts(specDir, it.key);
    const hit = securityHit(`${it.notes}\n${facts.text}`);
    const r = route({
      defaultTier: o.implementTier ?? "balanced",
      defaultEffort: o.defaultEffort ?? "medium",
      task: "implement",
      domain,
      risk: !!hit,
      complexity: it.complexity || undefined,
      items: undefined,
      files: facts.files,
      maxTier: o.maxTier ?? "balanced",
    });
    const why = [...r.reasons, ...(hit ? [`security-sensitive (${hit})`] : [])];
    const model = (reg && modelFor(reg, harness, r.tier)) ?? "";
    return { key: it.key, wave: it.wave, tier: r.tier, model, effort: r.effort, why: why.length ? why.join("; ") : "default" };
  });
}

const HEAD = "## Routing";

export function routingSection(routes: ItemRoute[]): string {
  const rows = routes.map((r) => `| ${r.key} | ${r.wave} | ${r.tier} | ${r.model} | ${r.effort} | ${r.why} |`);
  return [
    HEAD,
    "",
    "Written by `kcc route` from each item's Complexity, its files, its domain and CR-7 risk. `kcc-run` and the orchestrator read it;",
    "do not edit it by hand (rerun `kcc route`).",
    "",
    "| Item | Wave | Tier | Model | Effort | Why |",
    "|--|--|--|--|--|--|",
    ...rows,
    "",
  ].join("\n");
}

/** Replaces the plan's `## Routing` section, or puts one before `## Verification Steps` (else at the end). */
export function withRouting(plan: string, routes: ItemRoute[]): string {
  const text = plan.replace(/\r\n/g, "\n");
  const section = routingSection(routes);
  const re = /(^|\n)## Routing\b[\s\S]*?(?=\n## |\s*$)/;
  if (re.test(text)) return text.replace(re, (_m, lead: string) => `${lead}${section.trimEnd()}${String.fromCharCode(10)}`) + (text.endsWith("\n") ? "" : "\n");
  const at = text.search(/\n## Verification Steps\b/);
  if (at >= 0) return `${text.slice(0, at + 1)}${section}\n${text.slice(at + 1)}`;
  return `${text.trimEnd()}\n\n${section}`;
}

export interface RoutedSpec {
  spec: string;
  file: string;
  routes: ItemRoute[];
}

/** Routes every spec that has a plan.md and writes the table (unless dry). */
export function routeAll(root: string, only?: string, dry = false): RoutedSpec[] {
  const out: RoutedSpec[] = [];
  const specsRoot = join(root, "specs");
  if (!existsSync(specsRoot)) return out;
  const s = readSettings(root) as { routing?: { implement_max_tier?: Tier } } | undefined;
  const maxTier = s?.routing?.implement_max_tier ?? "balanced";
  const harness = (readJson<{ run?: { harness?: string } }>(join(root, ".KCC", "settings.json"))?.run?.harness) ?? "claude";
  for (const g of readdirSync(specsRoot, { withFileTypes: true })) {
    if (!g.isDirectory()) continue;
    for (const d of readdirSync(join(specsRoot, g.name), { withFileTypes: true })) {
      const id = /^SPEC-\d+/.exec(d.name)?.[0];
      if (!d.isDirectory() || !id || (only && id.toLowerCase() !== only.toLowerCase())) continue;
      const dir = join(specsRoot, g.name, d.name);
      const file = join(dir, "plan.md");
      if (!existsSync(file)) continue;
      const plan = readFileSync(file, "utf8");
      const routes = routePlan(root, dir, plan, { harness, maxTier });
      if (!routes.length) continue;
      if (!dry) writeFileSync(file, withRouting(plan, routes));
      out.push({ spec: id, file, routes });
    }
  }
  return out;
}
