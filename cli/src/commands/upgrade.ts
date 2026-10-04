import { parse, target, workspace } from "../args";
import { applyPayload, readLock } from "../lock";
import { payloadVersion } from "../payload";
import { runTool } from "../platform";
import { readSettings } from "../settings";
import { reapplyTailoring } from "./tailor";
import { reportApply } from "./init";

export async function upgrade(argv: string[]): Promise<number> {
  const { positionals, values } = parse(argv, ["force", "dry-run", "no-sync"], ["dir"]);
  const root = workspace(target(positionals, values.dir, false).dir);
  const before = readLock(root)?.payload_version ?? "unversioned";
  const dryRun = values["dry-run"] === true;

  const res = applyPayload(root, { force: values.force === true, dryRun });
  reportApply(res, `${dryRun ? "Would upgrade" : "Upgraded"} ${before} -> ${payloadVersion}`);
  if (dryRun) {
    for (const w of res.written) console.log(`  write  .KCC/${w}`);
    for (const r of res.removed) console.log(`  remove .KCC/${r}`);
    return 0;
  }

  // Files tailoring rewrote (the dialect registry) were just replaced by the shipped version.
  if (readSettings(root)?.tailoring) reapplyTailoring(root);

  if (values["no-sync"] !== true) {
    const r = runTool(root, "sync-adapters", ["--repo-root", root]);
    if (r.status !== 0) return r.status;
  }
  return res.conflicts.length ? 1 : 0;
}
