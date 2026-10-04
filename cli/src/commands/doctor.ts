import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parse } from "../args";
import { drift, readLock } from "../lock";
import { payloadVersion } from "../payload";
import { findRoot, isWindows, powershellExe, which } from "../platform";
import { readSettings } from "../settings";
import { CLI_VERSION } from "../version";

interface Finding {
  id: string;
  severity: "error" | "warning";
  fix_owner: "human";
  file: string;
  message: string;
}

function count(dir: string, ext: string): number {
  return existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(ext)).length : 0;
}

/** Health check of a KCC workspace. Output follows the tool contract; exit 1 when something must be fixed. */
export function doctor(argv: string[]): number {
  const { values } = parse(argv, ["json"], ["dir"]);
  const start = typeof values.dir === "string" ? values.dir : process.cwd();
  const root = findRoot(start);
  const findings: Finding[] = [];
  const add = (id: string, severity: Finding["severity"], file: string, message: string): void => {
    findings.push({ id, severity, fix_owner: "human", file, message });
  };

  if (isWindows) {
    if (!powershellExe()) add("DOCTOR-ENV-001", "error", "", "PowerShell was not found; the KCC tools cannot run. Install PowerShell.");
    if (!which("bash")) add("DOCTOR-ENV-002", "warning", "", "bash was not found; the Claude Code hooks and git hooks need it. Install Git for Windows.");
  } else if (!which("bash")) add("DOCTOR-ENV-001", "error", "", "bash was not found; the KCC tools cannot run.");
  if (!which("git")) add("DOCTOR-ENV-003", "warning", "", "git was not found; restore points fall back to file manifests and the git hooks are inactive.");

  if (!root) add("DOCTOR-INSTALL-001", "error", ".KCC", `no .KCC/ in ${start} or its parents. Run: kcc init`);
  else {
    const lock = readLock(root);
    if (!lock) add("DOCTOR-INSTALL-002", "warning", ".KCC/kcc.lock", ".KCC/ was not installed by the kcc CLI, so upgrades cannot tell local edits apart. Run: kcc init (adopts the folder, keeps your edits)");
    else {
      if (lock.payload_version !== payloadVersion) add("DOCTOR-VERSION-001", "warning", ".KCC/kcc.lock", `.KCC/ is at ${lock.payload_version}, this CLI ships ${payloadVersion}. Run: kcc upgrade`);
      const d = drift(root);
      for (const f of d.missing) add("DOCTOR-DRIFT-001", "error", `.KCC/${f}`, "framework file is missing. Run: kcc upgrade");
      if (d.modified.length) add("DOCTOR-DRIFT-002", "warning", ".KCC", `${d.modified.length} framework file(s) edited locally (kept on upgrade): ${d.modified.slice(0, 5).join(", ")}${d.modified.length > 5 ? ", ..." : ""}`);
    }

    // Generated adapters must mirror the capability sources.
    const agents = count(join(root, ".KCC", "capabilities", "agents"), ".md");
    const claudeAgents = join(root, ".claude", "agents");
    if (existsSync(claudeAgents) && count(claudeAgents, ".md") !== agents) add("DOCTOR-SYNC-001", "error", ".claude/agents", `${count(claudeAgents, ".md")} generated agents but ${agents} sources. Run: kcc sync`);

    const claudeSettings = join(root, ".claude", "settings.json");
    if (existsSync(claudeSettings)) {
      const text = readFileSync(claudeSettings, "utf8");
      if (!text.includes("kcc-limit-guard")) add("DOCTOR-HOOK-001", "warning", ".claude/settings.json", "the usage-limit guard hook is not configured. Merge the PreToolUse and statusLine entries from .KCC/kernel/templates/claude-settings.json");
      if (!text.includes("check-impl-lock")) add("DOCTOR-HOOK-002", "warning", ".claude/settings.json", "the implementation-lock hook is not configured. Merge the PreToolUse entry from .KCC/kernel/templates/claude-settings.json");
    }

    // Git hooks are expected once the human chose to use a repository.
    const decision = readSettings(root)?.repo?.decision;
    if (existsSync(join(root, ".git")) && decision && decision !== "skip") {
      for (const hook of ["pre-commit", "commit-msg", "pre-push"]) {
        if (!existsSync(join(root, ".KCC", "tools", "hooks", hook))) continue;
        const installed = join(root, ".git", "hooks", hook);
        if (!existsSync(installed) || !readFileSync(installed, "utf8").includes("KCC-")) {
          add("DOCTOR-HOOK-003", "error", `.git/hooks/${hook}`, "KCC git hook is not installed. Run: kcc tool repo-bootstrap --install-hook");
        }
      }
    }
  }

  const errors = findings.filter((f) => f.severity === "error").length;
  const warnings = findings.length - errors;
  if (values.json === true) {
    console.log(JSON.stringify({ tool: "kcc-doctor", version: CLI_VERSION, scope: "all", errors, warnings, status: errors ? "fail" : "pass", violations: findings }));
  } else {
    for (const f of findings) console.log(`${f.severity.toUpperCase()} ${f.id} ${f.file ? f.file + ": " : ""}${f.message}`);
    console.log(`Errors: ${errors}  Warnings: ${warnings}`);
  }
  return errors ? 1 : 0;
}
