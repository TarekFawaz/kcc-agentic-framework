import { parse, target, workspace } from "../args";
import { applyPayload, readLock } from "../lock";
import { payloadFiles, payloadVersion } from "../payload";
import { runTool } from "../platform";
import { migrateSettings, readSettings } from "../settings";
import { reapplyTailoring } from "./tailor";
import { reportApply } from "./init";

const MODEL_TIERS_NOTICE = [
  "Model tiers changed: spec/plan/design agents run on the balanced class and the implementer on balanced too (Haiku cost the same per token and coded worse).",
  "To keep earlier tiers for an agent, add a line to .KCC/model-overrides, for example:",
  "  implementer = strong-reasoning high",
  "then run: kcc sync. Agent files you edited locally are listed as conflicts above and keep their own tier.",
].join("\n");

export async function upgrade(argv: string[]): Promise<number> {
  const { positionals, values } = parse(argv, ["force", "dry-run", "no-sync"], ["dir"]);
  const root = workspace(target(positionals, values.dir, false).dir);
  const before = readLock(root)?.payload_version ?? "unversioned";
  const dryRun = values["dry-run"] === true;
  // Read before the migration below adds the key, so the notice shows once per workspace.
  const tiersNoticePending = before !== "unversioned" && readSettings(root)?.notices?.model_tiers_v2 !== true;

  const res = applyPayload(root, { force: values.force === true, dryRun });
  reportApply(res, `${dryRun ? "Would upgrade" : "Upgraded"} ${before} -> ${payloadVersion}`);
  // settings.json is project-owned, so keys a newer framework ships are added, never changed.
  const addedSettings = migrateSettings(root, payloadFiles().get("settings.json"), dryRun);
  if (addedSettings.length) console.log(`${dryRun ? "Would add" : "Added"} settings: ${addedSettings.join(", ")}`);
  if (dryRun) {
    for (const w of res.written) console.log(`  write  .KCC/${w}`);
    for (const r of res.removed) console.log(`  remove .KCC/${r}`);
    return 0;
  }
  if (tiersNoticePending) console.log(MODEL_TIERS_NOTICE);

  // Files tailoring rewrote (the dialect registry) were just replaced by the shipped version.
  if (readSettings(root)?.tailoring) reapplyTailoring(root);

  if (values["no-sync"] !== true) {
    const r = runTool(root, "sync-adapters", ["--repo-root", root]);
    if (r.status !== 0) return r.status;
  }
  return res.conflicts.length ? 1 : 0;
}
