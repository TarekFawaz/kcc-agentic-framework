import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { isWindows, powershellExe, toPowerShellArgs } from "../src/platform";

// Round 10: two architecture gates were prose only. QG-STATIC ("no raw SQL outside repository files, no dangerouslySetInnerHTML,
// ...") had no check in quality-gate, and QG-IMAGE scanned the source folder (trivy fs) while the built api image carried five
// CRITICAL OS-package vulnerabilities. Both tools (bash and PowerShell) must now fail on them. Every scenario runs on BOTH shells.
//
// The image scan is tested with a fake docker and a fake trivy on PATH (one tiny script, run by bun) so no daemon, network or
// vulnerability database is needed: FAKE_IMAGES lists the images that "exist"; FAKE_FIXABLE / FAKE_UNFIXED shape the trivy report.
setDefaultTimeout(900000);
const root = mkdtempSync(join(tmpdir(), "kcc-qgstatic-"));
const fake = join(root, "..", `fake-bin-${process.pid}-${Date.now()}`);
const ws = join(root, "src", "IDEA-001-x");
afterAll(() => {
  rmSync(root, { recursive: true, force: true });
  rmSync(fake, { recursive: true, force: true });
});

type Shell = "bash" | "powershell";
const shells: Shell[] = isWindows && powershellExe() ? ["bash", "powershell"] : ["bash"];

interface Check { id: string; name: string; status: string; severity: string; message: string; fix_owner: string; evidence: string | null }
interface Result { exit: number; status: string; checks: Check[]; stdout: string; stderr: string }

const put = (rel: string, text: string): void => {
  mkdirSync(dirname(join(root, rel)), { recursive: true });
  writeFileSync(join(root, rel), text);
};
const reset = (): void => {
  for (const d of ["src", "architecture"]) rmSync(join(root, d), { recursive: true, force: true });
  for (const f of ["docker-compose.yml", "compose.yml"]) rmSync(join(root, f), { force: true });
};
const slash = (p: string): string => p.replace(/\\/g, "/");

function run(shell: Shell, scope: string, env: Record<string, string> = {}): Promise<Result> {
  const tools = join(root, ".KCC", "tools");
  const pathKey = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") ?? "PATH";
  const childEnv: Record<string, string | undefined> = { ...process.env, ...env, [pathKey]: fake + delimiter + (process.env[pathKey] ?? "") };
  let cmd: string;
  let argv: string[];
  if (shell === "bash") {
    cmd = "bash";
    argv = [join(tools, "quality-gate.sh"), "--repo-root", slash(root), "--path", slash(ws), "--scope", scope, "--json"];
  } else {
    cmd = powershellExe() as string;
    argv = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(tools, "quality-gate.ps1"), ...toPowerShellArgs(["--repo-root", root, "--path", ws, "--scope", scope, "--json"])];
  }
  return new Promise((done) => {
    const child = spawn(cmd, argv, { cwd: root, env: childEnv as NodeJS.ProcessEnv, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (c: Buffer) => { stdout += c.toString("utf8"); });
    child.stderr.on("data", (c: Buffer) => { stderr += c.toString("utf8"); });
    child.on("close", (code) => {
      let checks: Check[] = [];
      let status = "?";
      try { const j = JSON.parse(stdout); checks = j.checks; status = j.status; } catch { /* reported through stdout/stderr below */ }
      done({ exit: code ?? 1, status, checks, stdout, stderr });
    });
  });
}
const both = (scope: string, env: Record<string, string> = {}): Promise<Array<[Shell, Result]>> =>
  Promise.all(shells.map(async (s) => [s, await run(s, scope, env)] as [Shell, Result]));
const find = (r: Result, id: string, name?: string): Check[] => r.checks.filter((c) => c.id === id && (!name || c.name === name));
const why = (s: Shell, r: Result): string => `[${s}] exit ${r.exit}\n${r.stdout.slice(0, 1500)}\n${r.stderr.slice(0, 500)}`;

beforeAll(() => {
  applyPayload(root);
  // One fake for docker and trivy, run by bun, behind a shim per shell (bash needs the extensionless file, PowerShell the .cmd).
  mkdirSync(fake, { recursive: true });
  writeFileSync(join(fake, "fake.js"), [
    'const fs = require("fs");',
    'const [tool, ...a] = process.argv.slice(2);',
    'const env = process.env;',
    'if (tool === "docker") {',
    '  const have = (env.FAKE_IMAGES || "").split(",").filter(Boolean);',
    '  process.exit(a[0] === "image" && a[1] === "inspect" ? (have.includes(a[2]) ? 0 : 1) : 0);',
    '}',
    'const out = a[a.indexOf("--output") + 1];',
    'if (a[0] === "fs") { fs.writeFileSync(out, JSON.stringify({ Results: [] })); process.exit(0); }',
    'const ignore = a.includes("--ignore-unfixed");',
    'const n = (+env.FAKE_FIXABLE || 0) + (ignore ? 0 : (+env.FAKE_UNFIXED || 0));',
    'const vulns = Array.from({ length: n }, (_, i) => ({ VulnerabilityID: "CVE-0000-" + i, Severity: "CRITICAL" }));',
    'fs.writeFileSync(out, JSON.stringify({ Results: [{ Vulnerabilities: vulns }] }, null, 2));',
    'process.exit(ignore && (+env.FAKE_FIXABLE || 0) > 0 ? 1 : 0);',
  ].join("\n"));
  const bun = process.execPath;
  for (const tool of ["docker", "trivy"]) {
    writeFileSync(join(fake, tool), `#!/bin/sh\nexec "${slash(bun)}" "${slash(join(fake, "fake.js"))}" ${tool} "$@"\n`, { mode: 0o755 });
    writeFileSync(join(fake, `${tool}.cmd`), `@"${bun}" "${join(fake, "fake.js")}" ${tool} %*\r\n`);
  }
});

const RULES = [
  "# QG-STATIC rules written by the architect",
  "id\tfiles\tforbidden\tallowed_in\tmessage",
  "SQL-001\t\\.(ts|tsx)$\tSELECT .* FROM\t(^|/)repository/\tno raw SQL outside repository files",
  "HTML-001\t\\.tsx$\tdangerouslySetInnerHTML\t\tno raw HTML injection",
  "",
].join("\n");

const COMPOSE = [
  "name: bp",
  "services:",
  "  api:",
  "    build:",
  "      context: .",
  "      dockerfile: src/IDEA-001-x/api/Dockerfile",
  "    ports:",
  '      - "127.0.0.1:3000:3000"',
  "  web:",
  "    build: ./web",
  "    image: bp-web:local   # explicit name",
  "  db:",
  "    image: postgres:16",
  "",
].join("\n");

describe("QG-STATIC and the built-image scan, bash and PowerShell", () => {
  test("no rules file: QG-STATIC is skipped; a Dockerfile without a compose file skips the built-image part", async () => {
    reset();
    put("src/IDEA-001-x/api/Dockerfile", "FROM scratch\n");
    put("src/IDEA-001-x/api/svc.ts", 'const q = "SELECT * FROM t";\n');
    for (const [s, r] of await both("static,image")) {
      const st = find(r, "QG-STATIC");
      expect(st.length, why(s, r)).toBe(1);
      expect(st[0]!.status, why(s, r)).toBe("skipped");
      expect(st[0]!.severity).toBe("none");
      expect(st[0]!.message).toContain("no architecture/static-rules.tsv declared");
      expect(find(r, "QG-IMAGE", "image-scan")[0]!.status, why(s, r)).toBe("pass"); // trivy fs part is unchanged
      const built = find(r, "QG-IMAGE", "image-scan-built");
      expect(built.length, why(s, r)).toBe(1);
      expect(built[0]!.status).toBe("skipped");
      expect(r.exit, why(s, r)).toBe(0);
    }
  });

  test("a forbidden hit outside allowed_in fails and names file:line; allowed, other-extension, pruned and lockfile hits do not count; images not built are deferred", async () => {
    reset();
    put("architecture/static-rules.tsv", RULES);
    put("src/IDEA-001-x/api/Dockerfile", "FROM scratch\n");
    put("src/IDEA-001-x/api/repository/user.ts", 'export const q = "SELECT id FROM users";\n'); // allowed_in
    put("src/IDEA-001-x/api/service.ts", 'export const a = 1;\nexport const q = "SELECT id FROM users";\n'); // hit, line 2
    put("src/IDEA-001-x/api/service.test.ts", 'it("x", () => { run("SELECT 1 FROM t"); });\n'); // tests are scanned like any other file
    put("src/IDEA-001-x/web/view.ts", "const h = { dangerouslySetInnerHTML: 1 };\n"); // HTML-001 only scans .tsx
    put("src/IDEA-001-x/web/view.tsx", "const ok = 1;\nconst h = <div dangerouslySetInnerHTML={x} />;\n"); // hit, line 2
    put("src/IDEA-001-x/node_modules/dep/index.ts", 'const q = "SELECT * FROM t";\n'); // pruned
    put("src/IDEA-001-x/dist/out.ts", 'const q = "SELECT * FROM t";\n'); // pruned
    put("docker-compose.yml", COMPOSE);
    for (const [s, r] of await both("static,image", { FAKE_IMAGES: "" })) {
      const st = find(r, "QG-STATIC");
      expect(st.length, why(s, r)).toBe(1);
      expect(st[0]!.status, why(s, r)).toBe("fail");
      expect(st[0]!.severity).toBe("error");
      expect(st[0]!.fix_owner).toBe("implementer");
      expect(st[0]!.message, why(s, r)).toContain("3 forbidden-pattern hit(s)");
      expect(st[0]!.message).toContain("api/service.ts:2 SQL-001"); // paths are relative to the workspace
      expect(st[0]!.evidence).toBeTruthy();
      const hits = readFileSync(st[0]!.evidence as string, "utf8").trim().split(/\r?\n/);
      expect(hits, why(s, r)).toEqual(["api/service.test.ts:1 SQL-001", "api/service.ts:2 SQL-001", "web/view.tsx:2 HTML-001"]);
      // images declared by compose with build: (api has no image: so compose names it bp-api); db has no build: and is ignored
      const built = find(r, "QG-IMAGE", "image-scan-built");
      expect(built.map((c) => c.status), why(s, r)).toEqual(["deferred", "deferred"]);
      expect(built[0]!.message).toContain("'bp-api'");
      expect(built[1]!.message).toContain("'bp-web:local'");
      expect(built[0]!.message).toContain("image not built: run docker compose build");
      expect(r.stdout).not.toContain("postgres");
      expect(r.exit, why(s, r)).toBe(1);
      rmSync(dirname(st[0]!.evidence as string), { recursive: true, force: true });
    }
  });

  test("hits only inside allowed_in pass; fixable image findings fail, unfixed ones are reported but do not gate", async () => {
    reset();
    put("architecture/static-rules.tsv", RULES);
    put("src/IDEA-001-x/api/Dockerfile", "FROM scratch\n");
    put("src/IDEA-001-x/api/repository/user.ts", 'export const q = "SELECT id FROM users";\n');
    put("docker-compose.yml", COMPOSE);
    for (const [s, r] of await both("static,image", { FAKE_IMAGES: "bp-api,bp-web:local", FAKE_FIXABLE: "2", FAKE_UNFIXED: "3" })) {
      const st = find(r, "QG-STATIC");
      expect(st[0]!.status, why(s, r)).toBe("pass");
      expect(st[0]!.message).toContain("no forbidden pattern found");
      const built = find(r, "QG-IMAGE", "image-scan-built");
      expect(built.map((c) => c.status), why(s, r)).toEqual(["fail", "fail"]);
      expect(built[0]!.severity).toBe("error");
      expect(built[0]!.fix_owner).toBe("infrastructure-implementer");
      expect(built[0]!.message, why(s, r)).toContain("bp-api");
      expect(built[0]!.message).toContain("2 fixable finding(s)");
      expect(built[0]!.message).toContain("3 unfixed, not gating");
      expect(find(r, "QG-IMAGE", "image-scan")[0]!.status).toBe("pass"); // the source scan alone said "no findings"
      expect(r.exit, why(s, r)).toBe(1);
    }
    for (const [s, r] of await both("static,image", { FAKE_IMAGES: "bp-api", FAKE_FIXABLE: "0", FAKE_UNFIXED: "5" })) {
      const built = find(r, "QG-IMAGE", "image-scan-built");
      expect(built.map((c) => c.status), why(s, r)).toEqual(["pass", "deferred"]); // bp-web:local is not built: still not a pass
      expect(built[0]!.message, why(s, r)).toContain("5 unfixed, not gating");
      expect(r.status).toBe("deferred");
      expect(r.exit).toBe(3);
    }
  });

  test("a malformed rules line is a failure with its line number", async () => {
    reset();
    put("architecture/static-rules.tsv", ["# header", "SQL-001\t\\.ts$\tSELECT\t\tfine", "BROKEN\tonly\tthree", "BAD-RE\t\\.ts$\t(unclosed\t\tx", ""].join("\n"));
    put("src/IDEA-001-x/api/svc.ts", "const x = 1;\n");
    for (const [s, r] of await both("static")) {
      const st = find(r, "QG-STATIC");
      expect(st.length, why(s, r)).toBe(1);
      expect(st[0]!.status, why(s, r)).toBe("fail");
      expect(st[0]!.severity).toBe("error");
      expect(st[0]!.message).toContain("line 3");
      expect(st[0]!.message).toContain("line 4 (BAD-RE)");
      expect(r.exit).toBe(1);
    }
  });
});
