import { afterAll, describe, expect, test } from "bun:test";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { reapplyTailoring } from "../src/commands/tailor";
import { applyPayload, drift, readLock } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { registerMcp } from "../src/mcp/register";
import { readSettings, writeSettings } from "../src/settings";

const root = mkdtempSync(join(tmpdir(), "kcc-test-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const kcc = (rel: string): string => join(root, ".KCC", rel);

describe("install and upgrade", () => {
  test("first install writes the whole payload and a lock", () => {
    const res = applyPayload(root);
    expect(res.written.length).toBe(payloadFiles().size);
    expect(res.conflicts).toEqual([]);
    expect(existsSync(kcc("kernel/contracts/tool-contract.md"))).toBe(true);
    expect(Object.keys(readLock(root)?.files ?? {}).length).toBe(payloadFiles().size - 1); // settings.json is user-owned
  });

  test("a second run changes nothing", () => {
    const res = applyPayload(root);
    expect(res.written).toEqual([]);
    expect(drift(root)).toEqual({ missing: [], modified: [] });
  });

  test("a locally edited file is a conflict and is kept", () => {
    appendFileSync(kcc("kernel/protocols/handover.md"), "\nlocal note\n");
    expect(drift(root).modified).toEqual(["kernel/protocols/handover.md"]);
    const res = applyPayload(root);
    expect(res.conflicts).toEqual(["kernel/protocols/handover.md"]);
    expect(readFileSync(kcc("kernel/protocols/handover.md"), "utf8")).toContain("local note");
  });

  test("--force replaces the edit", () => {
    const res = applyPayload(root, { force: true });
    expect(res.written).toEqual(["kernel/protocols/handover.md"]);
    expect(readFileSync(kcc("kernel/protocols/handover.md"), "utf8")).not.toContain("local note");
  });

  test("settings.json is never overwritten", () => {
    writeFileSync(kcc("settings.json"), '{"mine":true}\n');
    applyPayload(root, { force: true });
    expect(readFileSync(kcc("settings.json"), "utf8")).toContain("mine");
    rmSync(kcc("settings.json"));
    expect(applyPayload(root).written).toEqual(["settings.json"]);
  });

  test("a deleted file is restored", () => {
    rmSync(kcc("tools/kcc-run.sh"));
    expect(drift(root).missing).toEqual(["tools/kcc-run.sh"]);
    expect(applyPayload(root).written).toEqual(["tools/kcc-run.sh"]);
  });
});

describe("tailoring on disk", () => {
  test("excluded files are set aside, the registry is pruned, and upgrade keeps it that way", () => {
    const settings = readSettings(root) ?? {};
    settings.tailoring = { version: 1, applied_at: "now", context: {}, dialects: ["backend-python", "testing-unit"], exclude_agents: ["migrator"], exclude_skills: ["adapt-workflow"] };
    writeSettings(root, settings);
    reapplyTailoring(root);
    expect(existsSync(kcc("capabilities/agents/migrator.md"))).toBe(false);
    expect(existsSync(kcc(".tailored-out/capabilities/agents/migrator.md"))).toBe(true);
    expect(existsSync(kcc("kernel/protocols/dialects/backend-go.md"))).toBe(false);
    const registry = readFileSync(kcc("kernel/protocols/dialects/dialect-registry.md"), "utf8");
    expect(registry).toContain("[[backend-python]]");
    expect(registry).not.toContain("[[backend-go]]");
    expect(drift(root)).toEqual({ missing: [], modified: [] });

    const res = applyPayload(root);
    expect(res.conflicts).toEqual([]);
    reapplyTailoring(root);
    expect(existsSync(kcc("capabilities/agents/migrator.md"))).toBe(false);
    expect(readFileSync(kcc("kernel/protocols/dialects/dialect-registry.md"), "utf8")).not.toContain("[[backend-go]]");
  });

  test("reset brings everything back", () => {
    const settings = readSettings(root) ?? {};
    delete settings.tailoring;
    writeSettings(root, settings);
    reapplyTailoring(root);
    expect(existsSync(kcc("capabilities/agents/migrator.md"))).toBe(true);
    expect(existsSync(kcc("kernel/protocols/dialects/backend-go.md"))).toBe(true);
    expect(existsSync(kcc(".tailored-out"))).toBe(false);
    expect(existsSync(kcc("tailoring.exclude"))).toBe(false);
    expect(readFileSync(kcc("kernel/protocols/dialects/dialect-registry.md"), "utf8")).toContain("[[backend-go]]");
    expect(drift(root)).toEqual({ missing: [], modified: [] });
  });
});

describe("mcp registration", () => {
  test("adds kcc once and keeps other servers", () => {
    writeFileSync(join(root, ".mcp.json"), '{"mcpServers":{"other":{"command":"x"}}}');
    writeFileSync(join(root, "opencode.json"), '{"$schema":"https://opencode.ai/config.json"}');
    registerMcp(root);
    registerMcp(root);
    const claude = JSON.parse(readFileSync(join(root, ".mcp.json"), "utf8"));
    expect(Object.keys(claude.mcpServers)).toEqual(["other", "kcc"]);
    expect(claude.mcpServers.kcc).toEqual({ command: "kcc", args: ["mcp"] });
    const oc = JSON.parse(readFileSync(join(root, "opencode.json"), "utf8"));
    expect(oc.mcp.kcc.command).toEqual(["kcc", "mcp"]);
  });
});
