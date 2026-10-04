import { existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { HARNESSES, parse, target, UsageError } from "../args";
import { applyPayload, type ApplyResult } from "../lock";
import { payloadVersion } from "../payload";
import { runTool } from "../platform";
import { registerMcp } from "../mcp/register";
import { runTailor } from "./tailor";

export function reportApply(res: ApplyResult, verb: string): void {
  console.log(`${verb}: ${res.written.length} written, ${res.unchanged.length} unchanged, ${res.removed.length} removed.`);
  if (res.conflicts.length) {
    console.log(`Kept ${res.conflicts.length} locally edited file(s) (not overwritten):`);
    for (const c of res.conflicts) console.log(`  .KCC/${c}`);
    console.log("Re-run with --force to replace them with the shipped version.");
  }
  if (res.keptRemoved.length) {
    console.log(`Kept ${res.keptRemoved.length} edited file(s) this version no longer ships:`);
    for (const c of res.keptRemoved) console.log(`  .KCC/${c}`);
  }
}

export async function init(argv: string[]): Promise<number> {
  const { positionals, values } = parse(argv, ["force", "no-sync", "mcp", "yes", "from-baseline"], ["dir", "harness", "context"]);
  const t = target(positionals, values.dir, true);
  const harness = (values.harness as string | undefined) ?? t.harness ?? "all";
  if (!HARNESSES.includes(harness)) throw new UsageError(`unknown harness '${harness}'. Use one of: ${HARNESSES.join(", ")}`);
  const root = resolve(t.dir ?? process.cwd());
  mkdirSync(root, { recursive: true });

  const first = !existsSync(join(root, ".KCC", "kcc.lock"));
  const res = applyPayload(root, { force: values.force === true });
  reportApply(res, `KCC ${payloadVersion} ${first ? "installed into" : "refreshed in"} ${join(root, ".KCC")}`);

  // Tailor before generating adapters so only the fitted set is generated.
  if (values.context !== undefined || values["from-baseline"] === true) {
    const targs = ["--dir", root, "--no-sync"];
    if (typeof values.context === "string") targs.push("--context", values.context);
    if (values["from-baseline"] === true) targs.push("--from-baseline");
    if (values.yes === true) targs.push("--yes");
    const rc = await runTailor(targs);
    if (rc !== 0) return rc;
  }

  if (values["no-sync"] !== true) {
    const r = runTool(root, "framework-init", ["--harness", harness, "--repo-root", root]);
    if (r.status !== 0) {
      if (r.stderr) console.error(r.stderr);
      return r.status;
    }
  }

  if (values.mcp === true) registerMcp(root);

  console.log("");
  console.log("Next steps:");
  console.log("  kcc tailor          fit agents, skills, and dialects to this solution");
  console.log("  kcc doctor          check the installation");
  console.log("  auto <idea>         start the lifecycle inside your harness (or: kcc run --input \"<idea>\")");
  return 0;
}
