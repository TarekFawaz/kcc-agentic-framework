import { join } from "node:path";
import { readJson, writeJson } from "../fsutil";

interface HookCommand {
  type?: string;
  command?: string;
}
interface HookEntry {
  matcher?: string;
  hooks?: HookCommand[];
}
interface ClaudeSettings {
  statusLine?: unknown;
  hooks?: Record<string, HookEntry[]>;
  [key: string]: unknown;
}

/** The script a hook command runs, e.g. `kcc-hint` from `bash ".../kcc-hint.sh" inject`. */
function scriptOf(command: string | undefined): string {
  return /([A-Za-z0-9-]+)\.(?:sh|ps1)/.exec(command ?? "")?.[1] ?? command ?? "";
}

/**
 * Adds the KCC hook entries that `.claude/settings.json` lacks, taken from the kernel template.
 * Never removes or rewrites anything the human wrote. Returns the entries it added.
 */
export function mergeClaudeHooks(root: string, write: boolean): string[] {
  const template = readJson<ClaudeSettings>(join(root, ".KCC", "kernel", "templates", "claude-settings.json"));
  const path = join(root, ".claude", "settings.json");
  const current = readJson<ClaudeSettings>(path) ?? {};
  if (!template?.hooks) return [];
  const added: string[] = [];
  current.hooks ??= {};
  for (const [event, entries] of Object.entries(template.hooks)) {
    const have = (current.hooks[event] ??= []);
    for (const entry of entries) {
      for (const hook of entry.hooks ?? []) {
        const script = scriptOf(hook.command);
        // An earlier template used a cmd-style `%CLAUDE_PROJECT_DIR%` path, which the Git Bash that Claude Code
        // runs hooks in does not expand, so the hook failed on every session. Repair that command in place.
        const stale = have.flatMap((e) => e.hooks ?? []).find((h) => scriptOf(h.command) === script && (h.command ?? "").includes("%CLAUDE_PROJECT_DIR%"));
        if (stale) {
          stale.command = hook.command;
          added.push(`${event}: ${script} (repaired the %CLAUDE_PROJECT_DIR% path)`);
          continue;
        }
        const present = have.some((e) => (e.hooks ?? []).some((h) => scriptOf(h.command) === script));
        if (present) continue;
        // Reuse the human's entry with the same matcher, otherwise add the template's entry shape.
        const home = have.find((e) => (e.matcher ?? "") === (entry.matcher ?? ""));
        if (home) (home.hooks ??= []).push(hook);
        else have.push({ ...(entry.matcher !== undefined ? { matcher: entry.matcher } : {}), hooks: [hook] });
        added.push(`${event}: ${script}`);
      }
    }
  }
  if (template.statusLine && !current.statusLine) {
    current.statusLine = template.statusLine;
    added.push("statusLine: kcc-statusline");
  }
  if (write && added.length) writeJson(path, current);
  return added;
}
