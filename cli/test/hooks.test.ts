import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mergeClaudeHooks } from "../src/commands/hooks";
import { applyPayload } from "../src/lock";

const root = mkdtempSync(join(tmpdir(), "kcc-hooks-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("claude hook repair", () => {
  test("the shipped token-actuals hook does not use a %VAR% path", () => {
    applyPayload(root);
    const tpl = readFileSync(join(root, ".KCC", "kernel", "templates", "claude-settings.json"), "utf8");
    expect(tpl).not.toContain("%CLAUDE_PROJECT_DIR%");
    expect(tpl).toContain("record-token-actuals.ps1");
    expect(tpl).toContain("record-token-actuals.sh"); // the fallback for hosts without PowerShell
  });

  test("a hook that still uses the old %VAR% path is repaired in place, and nothing else is touched", () => {
    mkdirSync(join(root, ".claude"), { recursive: true });
    const old = {
      permissions: { allow: ["Bash(git:*)"] },
      hooks: { SessionEnd: [{ hooks: [{ type: "command", command: 'powershell -ExecutionPolicy Bypass -File "%CLAUDE_PROJECT_DIR%\\.KCC\\tools\\record-token-actuals.ps1" -FromHookStdin' }] }] },
    };
    writeFileSync(join(root, ".claude", "settings.json"), JSON.stringify(old));
    const changes = mergeClaudeHooks(root, true);
    expect(changes.some((c) => c.includes("record-token-actuals") && c.includes("repaired"))).toBe(true);
    const after = JSON.parse(readFileSync(join(root, ".claude", "settings.json"), "utf8"));
    expect(after.permissions.allow).toEqual(["Bash(git:*)"]);
    expect(JSON.stringify(after.hooks.SessionEnd)).not.toContain("%CLAUDE_PROJECT_DIR%");
    expect(after.hooks.SessionEnd).toHaveLength(1); // repaired, not duplicated
    expect(mergeClaudeHooks(root, true).filter((c) => c.includes("record-token-actuals"))).toEqual([]); // idempotent
  });
});
