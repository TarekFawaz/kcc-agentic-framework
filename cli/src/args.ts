import { parseArgs } from "node:util";
import { resolve } from "node:path";
import { findRoot } from "./platform";

export class UsageError extends Error {}

export interface Parsed {
  positionals: string[];
  values: Record<string, string | boolean | undefined>;
}

/** `flags` are booleans, `options` take a value. Unknown arguments are a usage error. */
export function parse(argv: string[], flags: string[], options: string[]): Parsed {
  const spec: Record<string, { type: "boolean" | "string" }> = {};
  for (const f of flags) spec[f] = { type: "boolean" };
  for (const o of options) spec[o] = { type: "string" };
  try {
    const r = parseArgs({ args: argv, options: spec, allowPositionals: true, strict: true });
    return { positionals: r.positionals, values: r.values as Parsed["values"] };
  } catch (e) {
    throw new UsageError((e as Error).message);
  }
}

export const HARNESSES = ["claude", "codex", "opencode", "generic", "ollama", "all"];

/** The workspace: `--dir`, or the nearest parent that already holds `.KCC/`. */
export function workspace(dir: string | boolean | undefined, mustExist = true): string {
  const start = resolve(typeof dir === "string" ? dir : process.cwd());
  const root = findRoot(start);
  if (root) return root;
  if (mustExist) throw new UsageError(`no .KCC/ found in ${start} or its parents. Run 'kcc init' first.`);
  return start;
}
