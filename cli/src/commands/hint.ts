import { parse, UsageError, workspace } from "../args";
import { runTool } from "../platform";

const SUBCOMMANDS = ["add", "list", "clear", "pending"];

/**
 * `kcc hint "<text>" [--to all|main|subagents|<agent>] [--expires <minutes>]`
 * `kcc hint --list | --clear <H-NNN|all> | --pending [--for <agent>]`
 * Also reachable as `kcc --hint "<text>"`. The store and the delivery hooks live in
 * .KCC/tools/kcc-hint.*; see .KCC/kernel/protocols/hints.md.
 */
export function hint(argv: string[]): number {
  const { positionals, values } = parse(argv, ["list", "pending", "all", "json", "hint"], ["to", "expires", "by", "spec", "clear", "for", "dir"]);
  const root = workspace(values.dir);
  const args: string[] = [];
  let words = positionals;
  const first = words[0];

  if (typeof values.clear === "string") args.push("clear", values.clear);
  else if (values.list || first === "list") args.push("list");
  else if (values.pending || first === "pending") args.push("pending");
  else if (first === "clear") {
    if (!words[1]) throw new UsageError("usage: kcc hint clear <H-NNN|all>");
    args.push("clear", words[1]);
  } else {
    if (first === "add") words = words.slice(1);
    const text = words.join(" ").trim();
    if (!text) throw new UsageError('usage: kcc hint "<text>" [--to all|main|subagents|<agent>] [--expires <minutes>]   |   kcc hint --list | --clear <id|all> | --pending');
    args.push("add", text);
  }
  if (!SUBCOMMANDS.includes(args[0] ?? "")) throw new UsageError("unknown hint command");

  for (const [flag, name] of [["to", "--to"], ["expires", "--expires-minutes"], ["by", "--by"], ["spec", "--spec"], ["for", "--for"]] as const) {
    const v = values[flag];
    if (typeof v === "string") args.push(name, v);
  }
  if (values.all) args.push("--all");
  if (values.json) args.push("--json");
  args.push("--repo-root", root);

  const r = runTool(root, "kcc-hint", args);
  if (r.stderr) console.error(r.stderr);
  return r.status;
}
