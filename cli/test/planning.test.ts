import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { isWindows, runTool } from "../src/platform";

// Fixes found by test round 02: deliverables were git-ignored, versions were never checked, ADRs
// waited for a human in unattended runs, and the kernel had no standards to cite.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-plan-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const text = (rel: string): string => payloadFiles().get(rel)!.toString("utf8");

describe("repo-bootstrap .gitignore", () => {
  test("ideas, specs and src are committed; run state, secrets and dependencies are not", () => {
    for (const f of ["tools/repo-bootstrap.ps1", "tools/repo-bootstrap.sh", "tools/sync-adapters.ps1", "tools/sync-adapters.sh"]) {
      const body = text(f);
      const block = body.slice(body.indexOf("# KCC generated cell outputs"), body.indexOf("desktop.ini"));
      const lines = block.split(/\r?\n/);
      for (const kept of ["src/", "specs/IDEA-*-Specs/", "ideation/IDEA-*/"]) expect(lines).not.toContain(kept);
      for (const ignored of ["coordination/run/", "node_modules/", ".env", "!.env.example"]) expect(lines).toContain(ignored);
    }
  });
});

describe("repo-bootstrap init-local", () => {
  test("bootstraps a fresh folder quickly (the pre-commit lock check skips non-src files)", () => {
    const dir = mkdtempSync(join(tmpdir(), "kcc-boot-"));
    try {
      applyPayload(dir);
      const t0 = Date.now();
      // a CI runner has no git identity in its config; the bootstrap accepts git's own environment identity
      const ident = { GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@example.com", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@example.com" };
      const r = runTool(dir, "repo-bootstrap", ["--apply", "init-local", "--repo-root", dir], { capture: true, env: ident });
      if (r.status !== 0) console.error(r.stdout, r.stderr);
      expect(r.status).toBe(0);
      expect(Date.now() - t0).toBeLessThan(120000); // it used to hang for many minutes
      expect(readFileSync(join(dir, ".gitignore"), "utf8")).toContain("coordination/run/");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("toolchain-preflight version ranges", () => {
  test("setup", () => {
    applyPayload(root);
  });
  const pre = (spec: string) => runTool(root, "toolchain-preflight", isWindows ? ["--tools", spec] : [spec], { capture: true });
  test("a tool below the plan's range is reported WRONG and fails the gate", () => {
    const r = pre("git@>=999");
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("WRONG");
  });
  test("a tool inside the range passes", () => {
    const r = pre("git@>=1");
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("PRESENT");
  });
});

describe("standards and ADR status", () => {
  test("the kernel ships a standards catalogue and a style catalogue", () => {
    const cat = text("kernel/protocols/standards-catalog.md");
    for (const s of ["OWASP ASVS", "Argon2id", "RFC 9457", "WCAG 2.2", "ISO/IEC 25010", "Twelve-Factor", "CycloneDX"]) expect(cat).toContain(s);
    const styles = text("kernel/protocols/architecture-styles.md");
    for (const s of ["Modular monolith", "Microservices", "CQRS", "Serverless", "Backend for Frontend"]) expect(styles).toContain(s);
  });
  test("unattended runs accept standard-backed and assumed ADRs, so the plan does not stop on them", () => {
    expect(text("kernel/protocols/architecture-governance.md")).toContain("Accepted (assumed)");
    expect(text("capabilities/agents/planner.md")).toContain("never\n   add a \"STOP before implement\"");
    expect(text("capabilities/agents/planner.md")).toContain("## Toolchain");
    expect(text("capabilities/agents/architect.md")).toContain("standards-catalog.md");
  });
});
