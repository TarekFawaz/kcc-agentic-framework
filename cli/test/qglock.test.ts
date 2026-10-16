import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// Round 10: an npm workspaces monorepo keeps ONE lockfile at the repository root, above the spec's src folder. QG-LOCK looked only
// inside the folder and failed for "no lockfile"; the implementer correctly refused to fake one and the spec stopped at a gate.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-qglock-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const put = (rel: string, text: string): void => {
  mkdirSync(join(root, rel, ".."), { recursive: true });
  writeFileSync(join(root, rel), text);
};
const lock = (): { status: string; message: string } => {
  const r = runTool(root, "quality-gate", ["--repo-root", root, "--path", join(root, "src", "IDEA-001-x"), "--scope", "lock", "--json"], { capture: true });
  const text = r.stdout;
  const i = text.indexOf('"QG-LOCK"');
  const seg = i >= 0 ? text.slice(i, i + 600) : text;
  return { status: /"status"\s*:\s*"(\w+)"/.exec(seg)?.[1] ?? "?", message: seg };
};

describe("QG-LOCK and a workspace lockfile above the project", () => {
  test("a lockfile at the root of an npm workspace is accepted; a stray root lockfile with no workspaces is not", () => {
    applyPayload(root);
    put("src/IDEA-001-x/api/package.json", JSON.stringify({ name: "api", scripts: { test: "echo ok" } }));
    put("package.json", JSON.stringify({ name: "root", private: true }));
    put("package-lock.json", "{}");
    expect(lock().status).toBe("fail"); // a root lockfile with no workspaces declaration is somebody else's
    put("package.json", JSON.stringify({ name: "root", private: true, workspaces: ["src/IDEA-001-x/api"] }));
    expect(lock().status).toBe("pass");
  });
});
