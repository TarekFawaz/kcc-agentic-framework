import { existsSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { basename, extname, join, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { parse as parseYaml } from "yaml";
import { parse, target, UsageError, workspace } from "../args";
import { detectFromBaseline, detectFromRepo, detectFromText, type Detected } from "../context/detect";
import { DEPLOYMENTS, PROJECT_TYPES, SENSITIVITIES, STACKS, defaultContext, mergeContext, type SolutionContext } from "../context/model";
import { planTailoring, type TailoringPlan } from "../context/rules";
import { contentHash, moveFile, writeFileEnsured } from "../fsutil";
import { kccDir, readLock, TAILORED_OUT, writeLock } from "../lock";
import { payloadFiles } from "../payload";
import { runTool } from "../platform";
import { readSettings, writeSettings, type Tailoring } from "../settings";

const DIALECT_DIR = "kernel/protocols/dialects";
const REGISTRY = `${DIALECT_DIR}/dialect-registry.md`;

/** Folders where sync-adapters writes one entry per agent or skill. */
const GENERATED = {
  agents: [".claude/agents", ".codex/agents", ".opencode/agents", ".agents/agents"],
  skills: [".claude/skills", ".codex/skills", ".opencode/commands", ".opencode/skills", ".agents/skills"],
};

function shippedDialects(): string[] {
  const out: string[] = [];
  for (const rel of payloadFiles().keys()) {
    if (rel.startsWith(`${DIALECT_DIR}/`) && rel !== REGISTRY) out.push(basename(rel, ".md"));
  }
  return out.sort();
}

function excludedRels(t: Pick<Tailoring, "dialects" | "exclude_agents" | "exclude_skills">): string[] {
  const keep = new Set(t.dialects);
  const rels = shippedDialects().filter((d) => !keep.has(d)).map((d) => `${DIALECT_DIR}/${d}.md`);
  for (const a of t.exclude_agents) rels.push(`capabilities/agents/${a}.md`);
  for (const s of t.exclude_skills) rels.push(`capabilities/skills/${s}.md`);
  const shipped = payloadFiles();
  return rels.filter((r) => shipped.has(r)).sort();
}

/** Drops the registry rows of dialects that are not kept. */
export function pruneRegistry(text: string, keep: Set<string>): string {
  return text
    .split("\n")
    .filter((line) => {
      const m = /^\|[^|]*\|\s*\[\[([a-z0-9-]+)\]\]\s*\|\s*$/.exec(line);
      return !m || keep.has(m[1] ?? "");
    })
    .join("\n");
}

function removeGenerated(root: string, kind: keyof typeof GENERATED, names: string[]): void {
  const drop = new Set(names);
  for (const dir of GENERATED[kind]) {
    const full = join(root, dir);
    if (!existsSync(full)) continue;
    for (const entry of readdirSync(full)) {
      if (drop.has(basename(entry, extname(entry)))) rmSync(join(full, entry), { recursive: true, force: true });
    }
  }
}

/** Makes the files under `.KCC/` match the stored tailoring. Safe to run repeatedly. */
function materialize(root: string, t: Tailoring | undefined): void {
  const dir = kccDir(root);
  const shipped = payloadFiles();
  const excluded = new Set(t ? excludedRels(t) : []);
  const lock = readLock(root);

  // Bring back anything that was set aside earlier and is wanted again.
  for (const rel of shipped.keys()) {
    const aside = join(dir, TAILORED_OUT, rel);
    const live = join(dir, rel);
    if (excluded.has(rel)) {
      if (existsSync(live)) moveFile(live, aside);
    } else if (existsSync(aside)) moveFile(aside, live);
  }
  if (excluded.size === 0) rmSync(join(dir, TAILORED_OUT), { recursive: true, force: true });

  const excludeFile = join(dir, "tailoring.exclude");
  if (t) {
    const header = "# Written by `kcc tailor`. Framework files set aside for this solution (see kernel/protocols/tailoring.md).\n";
    writeFileEnsured(excludeFile, header + [...excluded].join("\n") + "\n");
  } else rmSync(excludeFile, { force: true });

  // The registry lists only the dialects that are present.
  const original = shipped.get(REGISTRY);
  if (original) {
    const text = original.toString("utf8");
    const next = t ? pruneRegistry(text, new Set(t.dialects)) : text;
    const live = join(dir, REGISTRY);
    const local = existsSync(live) ? contentHash(readFileSync(live)) : undefined;
    const ours = local === undefined || local === contentHash(text) || local === lock?.derived[REGISTRY];
    if (ours) {
      writeFileEnsured(live, next);
      if (lock) {
        if (next === text) delete lock.derived[REGISTRY];
        else lock.derived[REGISTRY] = contentHash(next);
        writeLock(root, lock);
      }
    } else console.log(`Kept your edited .KCC/${REGISTRY}; remove the rows of dropped dialects by hand.`);
  }

  if (t) {
    removeGenerated(root, "agents", t.exclude_agents);
    removeGenerated(root, "skills", t.exclude_skills);
  }
}

export function reapplyTailoring(root: string): void {
  materialize(root, readSettings(root)?.tailoring);
}

function overlay(ctx: SolutionContext, d: Detected | undefined): void {
  if (!d) return;
  if (d.name && !ctx.name) ctx.name = d.name;
  if (d.project_type) ctx.project_type = d.project_type;
  if (d.stacks?.length) ctx.stacks = [...new Set([...ctx.stacks, ...d.stacks])];
  if (d.has_ui !== undefined) ctx.has_ui = d.has_ui;
  if (d.deployment) ctx.deployment = d.deployment;
  if (d.existing_codebase !== undefined) ctx.existing_codebase = d.existing_codebase;
}

async function ask(ctx: SolutionContext): Promise<void> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const q = async (label: string, def: string, hint = ""): Promise<string> => {
    const a = (await rl.question(`${label}${hint ? ` (${hint})` : ""} [${def}]: `)).trim();
    return a === "" ? def : a;
  };
  const yn = (b: boolean): string => (b ? "y" : "n");
  try {
    console.log("Describe the solution. Press Enter to accept the value in brackets.\n");
    for (;;) {
      const answers: Record<string, unknown> = {
        name: await q("Solution name", ctx.name || "my-solution"),
        project_type: await q("Project type", ctx.project_type, PROJECT_TYPES.join(" | ")),
        stacks: await q("Stacks, comma separated", ctx.stacks.join(",") || "none", STACKS.join(" | ")),
        has_ui: await q("Has a user interface", yn(ctx.has_ui), "y/n"),
        deployment: await q("Deployment target", ctx.deployment, DEPLOYMENTS.join(" | ")),
        existing_codebase: await q("Existing codebase", yn(ctx.existing_codebase), "y/n"),
        import_workflows: await q("Import an existing agent workflow (Cursor, Aider, ...)", yn(ctx.import_workflows), "y/n"),
        data_sensitivity: await q("Data sensitivity", ctx.data_sensitivity, SENSITIVITIES.join(" | ")),
        performance_tests: await q("Performance tests needed", yn(ctx.performance_tests), "y/n"),
        coverage_min_pct: await q("Minimum test coverage %", String(ctx.coverage_min_pct ?? 80)),
      };
      if (answers.stacks === "none") answers.stacks = "";
      const problems = mergeContext(ctx, answers);
      if (problems.length === 0) return;
      console.log("\nPlease correct:");
      for (const p of problems) console.log(`  ${p}`);
      console.log("");
    }
  } finally {
    rl.close();
  }
}

function loadContextFile(path: string, ctx: SolutionContext): { brief?: string; problems: string[] } {
  if (!existsSync(path)) throw new UsageError(`context file not found: ${path}`);
  const text = readFileSync(path, "utf8").replace(/^﻿/, "");
  const ext = extname(path).toLowerCase();
  if (ext === ".json" || ext === ".yml" || ext === ".yaml") {
    let data: unknown;
    try {
      data = ext === ".json" ? JSON.parse(text) : parseYaml(text);
    } catch (e) {
      throw new UsageError(`could not parse ${path}: ${(e as Error).message}`);
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) throw new UsageError(`${path} must hold a mapping of context keys`);
    const rec = data as Record<string, unknown>;
    return { brief: typeof rec.brief === "string" ? rec.brief : undefined, problems: mergeContext(ctx, rec) };
  }
  // Free-form brief: keep it for the /tailor-workflow skill and scan it for hints.
  overlay(ctx, detectFromText(text));
  return { brief: text, problems: [] };
}

function printPlan(ctx: SolutionContext, plan: TailoringPlan): void {
  console.log(`\nSolution: ${ctx.name || "(unnamed)"} | ${ctx.project_type} | stacks: ${ctx.stacks.join(", ") || "not specified"} | UI: ${ctx.has_ui ? "yes" : "no"} | deployment: ${ctx.deployment}`);
  for (const r of plan.reasons) console.log(`  - ${r}`);
  console.log(`Dialects kept (${plan.dialects.length}): ${plan.dialects.join(", ")}`);
  console.log(`Agents dropped (${plan.exclude_agents.length}): ${plan.exclude_agents.join(", ") || "none"}`);
  console.log(`Skills dropped (${plan.exclude_skills.length}): ${plan.exclude_skills.join(", ") || "none"}`);
}

export async function runTailor(argv: string[]): Promise<number> {
  const { positionals, values } = parse(argv, ["from-baseline", "reset", "show", "yes", "dry-run", "no-sync", "json"], ["dir", "context"]);
  const root = workspace(target(positionals, values.dir, false).dir);
  const settings = readSettings(root) ?? {};
  const sync = (): number => (values["no-sync"] === true ? 0 : runTool(root, "sync-adapters", ["--repo-root", root]).status);

  if (values.show === true) {
    if (values.json === true) console.log(JSON.stringify(settings.tailoring ?? null, null, 2));
    else if (!settings.tailoring) console.log("Not tailored: the full generic framework is active.");
    else {
      const t = settings.tailoring;
      console.log(`Tailored ${t.applied_at}`);
      console.log(`Dialects: ${t.dialects.join(", ")}`);
      console.log(`Agents dropped: ${t.exclude_agents.join(", ") || "none"}`);
      console.log(`Skills dropped: ${t.exclude_skills.join(", ") || "none"}`);
    }
    return 0;
  }

  if (values.reset === true) {
    delete settings.tailoring;
    writeSettings(root, settings);
    materialize(root, undefined);
    console.log("Tailoring removed: the full generic framework is restored.");
    return sync();
  }

  // Later sources win: defaults < previous tailoring < repo markers < baseline < context file < answers.
  const ctx = defaultContext();
  if (settings.tailoring) mergeContext(ctx, settings.tailoring.context);
  overlay(ctx, detectFromRepo(root));
  if (values["from-baseline"] === true) {
    const b = detectFromBaseline(root);
    if (!b) throw new UsageError("no solution/ baseline found. Run /solution-onboard first, or use --context.");
    overlay(ctx, b);
  }
  let brief: string | undefined;
  if (typeof values.context === "string") {
    const r = loadContextFile(resolve(values.context), ctx);
    if (r.problems.length) throw new UsageError(`invalid context file:\n  ${r.problems.join("\n  ")}`);
    brief = r.brief;
  }
  const scripted = values.yes === true || typeof values.context === "string" || values["from-baseline"] === true;
  if (!scripted) {
    if (!process.stdin.isTTY) throw new UsageError("no terminal for questions. Pass --context <file>, --from-baseline, or --yes.");
    await ask(ctx);
  }

  const plan = planTailoring(ctx, shippedDialects());
  const unknown = (ctx.dialects ?? []).filter((d) => !plan.dialects.includes(d));
  if (unknown.length) throw new UsageError(`unknown dialect(s): ${unknown.join(", ")}`);
  if (values.json === true) console.log(JSON.stringify({ context: ctx, ...plan }, null, 2));
  else printPlan(ctx, plan);
  if (values["dry-run"] === true) return 0;

  const tailoring: Tailoring = {
    version: 1,
    applied_at: new Date().toISOString(),
    context: { ...ctx },
    dialects: plan.dialects,
    exclude_agents: plan.exclude_agents,
    exclude_skills: plan.exclude_skills,
  };
  settings.tailoring = tailoring;
  if (ctx.coverage_min_pct !== null) settings.quality = { ...settings.quality, coverage_min_pct: ctx.coverage_min_pct };
  writeSettings(root, settings);
  if (brief) writeFileEnsured(join(kccDir(root), "context.md"), brief.endsWith("\n") ? brief : brief + "\n");
  materialize(root, tailoring);

  if (values.json !== true) {
    console.log("\nTailoring applied. Undo with: kcc tailor --reset");
    console.log("Optional: run /tailor-workflow in your harness to draft solution-specific agent additions.");
  }
  return sync();
}
