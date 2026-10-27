import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parse, UsageError, workspace } from "../args";
import { which } from "../platform";
import { loadRegistry, type Registry } from "../run/router";

/**
 * `kcc models [--check] [--refresh] [--deep] [--json]`
 *   lists the registry (kernel/models.json): the model of each tier per harness.
 *   --check   probes every pinned Claude id against the installed `claude` (one tiny call each) and
 *             compares the registry with the generated .claude/agents files; exit 1 on a mismatch or
 *             an unknown id.
 *   --refresh also asks what each alias (opus/sonnet/haiku) resolves to today, so a newer generation
 *             than the pinned id is noticed. Needs `claude` on PATH; each probe costs a few tokens.
 *   --deep    also probes the DeepThinking tier. Left out by default because one probe costs about
 *             $0.80 (protocols/deep-thinking.md); the command prints that before it runs.
 */
interface Probe {
  id: string;
  ok: boolean;
  resolved?: string;
  unrecognized: boolean;
  note?: string;
}

export function probeClaude(model: string): Probe {
  if (!which("claude")) return { id: model, ok: false, unrecognized: false, note: "claude not on PATH" };
  const r = spawnSync("claude", ["-p", "--model", model, "--output-format", "json", "--max-turns", "1", "Reply with the single word OK."], { encoding: "utf8", timeout: 120000, input: "" });
  const out = (r.stdout ?? "") + (r.stderr ?? "");
  const unrecognized = /unrecognized_model/i.test(out);
  let resolved: string | undefined;
  const j = /\{[\s\S]*\}\s*$/.exec(r.stdout ?? "");
  if (j) {
    try {
      const d = JSON.parse(j[0]) as { modelUsage?: Record<string, unknown>; is_error?: boolean };
      const keys = Object.keys(d.modelUsage ?? {}).filter((k) => k !== "claude-haiku-4-5-20251001" || model.includes("4-5"));
      resolved = keys.find((k) => k.includes(model.replace(/^claude-/, "").split("-").slice(0, 2).join("-"))) ?? keys[keys.length - 1];
      return { id: model, ok: !d.is_error && r.status === 0, resolved, unrecognized };
    } catch {
      /* fall through */
    }
  }
  return { id: model, ok: r.status === 0, resolved, unrecognized, note: r.status === 0 ? undefined : out.slice(-200) };
}

/** `model:` of every generated Claude agent file. */
function agentModels(root: string): Record<string, string> {
  const dir = join(root, ".claude", "agents");
  const out: Record<string, string> = {};
  if (!existsSync(dir)) return out;
  for (const f of readdirSync(dir).filter((x) => x.endsWith(".md"))) {
    const t = readFileSync(join(dir, f), "utf8");
    const m = /^model:\s*(\S+)/m.exec(t);
    if (m) out[f.replace(/\.md$/, "")] = m[1]!;
  }
  return out;
}

export function registryAge(reg: Registry): number {
  const v = Date.parse(reg.verified ?? "");
  return isNaN(v) ? Infinity : Math.max(0, Math.floor((Date.now() - v) / 86400000));
}

export function models(argv: string[]): number {
  const { values } = parse(argv, ["check", "refresh", "deep", "json"], ["dir"]);
  const root = workspace(values.dir);
  const reg = loadRegistry(root);
  if (!reg) throw new UsageError("no .KCC/kernel/models.json (run kcc upgrade)");
  const problems: string[] = [];
  const age = registryAge(reg);
  if (values.json && !values.check && !values.refresh) {
    console.log(JSON.stringify(reg, null, 2));
    return 0;
  }
  console.log(`Model registry (verified ${reg.verified}, ${age === Infinity ? "unknown age" : age + " days ago"})`);
  for (const [h, tiers] of Object.entries(reg.harnesses)) {
    const row = ["strong", "balanced", "fast"].map((t) => `${t}=${tiers[t]?.id ?? "-"}`).join("  ");
    console.log(`  ${h.padEnd(9)} ${row}`);
  }
  const deepId = reg.harnesses.claude?.deep?.id;
  if (deepId) console.log(`  deep      ${deepId} (DeepThinking: human-approved, ~$0.80 per call before any work; see protocols/deep-thinking.md)`);
  if (age > 30) problems.push(`the registry was last verified ${age} days ago; run kcc models --refresh`);

  // The generated agents must pin the registry's ids (sync-adapters carries its own copy of the map).
  const pinned = new Set(["strong", "balanced", "fast"].map((t) => reg.harnesses.claude?.[t]?.id).filter(Boolean) as string[]);
  const agents = agentModels(root);
  for (const [name, m] of Object.entries(agents)) {
    if (!pinned.has(m)) problems.push(`.claude/agents/${name}.md pins '${m}', which is not a registry id (${[...pinned].join(", ")}); run kcc sync`);
  }

  if (values.check || values.refresh) {
    if (!which("claude")) problems.push("claude is not on PATH: the pinned ids were not probed");
    else {
      const probeTiers: ("strong" | "balanced" | "fast" | "deep")[] = ["strong", "balanced", "fast"];
      if (values.deep) {
        probeTiers.push("deep");
        console.log("  --deep: probing the deep tier costs about $0.80.");
      } else if (deepId) console.log("  probe deep     not run (costs about $0.80; add --deep)");
      for (const t of probeTiers) {
        const e = reg.harnesses.claude?.[t];
        if (!e) continue;
        const p = probeClaude(e.id);
        const state = !p.ok ? "FAILED" : p.unrecognized ? "works, but this Claude Code build does not know it (update Claude Code)" : "ok";
        console.log(`  probe ${t.padEnd(8)} ${e.id}: ${state}${p.resolved && p.resolved !== e.id ? ` (ran as ${p.resolved})` : ""}`);
        if (!p.ok) problems.push(`${e.id} failed to run: ${p.note ?? "see above"}`);
        if (values.refresh && e.alias) {
          const a = probeClaude(e.alias);
          const newer = a.resolved && a.resolved !== e.id && a.resolved !== p.resolved;
          console.log(`  alias ${e.alias.padEnd(8)} -> ${a.resolved ?? "?"}${newer ? "  <- differs from the pinned id: a newer or older generation" : ""}`);
        }
      }
    }
  }
  if (problems.length) {
    for (const p of problems) console.log(`PROBLEM ${p}`);
    return 1;
  }
  console.log("OK");
  return 0;
}
