import { describe, expect, test } from "bun:test";
import { pruneRegistry } from "../src/commands/tailor";
import { detectFromText } from "../src/context/detect";
import { defaultContext, mergeContext } from "../src/context/model";
import { planTailoring } from "../src/context/rules";
import { contentHash } from "../src/fsutil";
import { headings, parseSkill, section, slug } from "../src/mcp/content";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { toBashArgs, toPowerShellArgs } from "../src/platform";
import { detectLimit, loadPatterns, parseReset, scanTranscript, sessionId } from "../src/run/limits";

const DIALECTS = ["backend-go", "backend-python", "devops-cloud", "devops-k8s-onprem-agnostic", "frontend-general", "frontend-react", "fullstack-python", "testing-integration", "testing-performance", "testing-security", "testing-unit"];

describe("argument translation", () => {
  test("bash flags become PowerShell flags, values stay", () => {
    expect(toPowerShellArgs(["--repo-root", "C:\\x y", "--json", "SPEC-001", "--dry-run"])).toEqual(["-RepoRoot", "C:\\x y", "-Json", "SPEC-001", "-DryRun"]);
  });
  test("PowerShell flags become bash flags", () => {
    expect(toBashArgs(["-RepoRoot", "/x", "-DryRun", "-Json"])).toEqual(["--repo-root", "/x", "--dry-run", "--json"]);
  });
});

describe("content hash", () => {
  test("CRLF and LF hash the same", () => {
    expect(contentHash("a\r\nb\r\n")).toBe(contentHash("a\nb\n"));
    expect(contentHash("a\nb\n")).not.toBe(contentHash("a\nc\n"));
  });
});

describe("solution context", () => {
  test("merge validates enums and normalises stacks", () => {
    const ctx = defaultContext();
    const problems = mergeContext(ctx, { project_type: "CLI-Tool", stacks: "Python, C#, node", has_ui: "no", deployment: "moon" });
    expect(ctx.project_type).toBe("cli-tool");
    expect(ctx.stacks).toEqual(["python", "dotnet", "nodejs"]);
    expect(ctx.has_ui).toBe(false);
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("deployment");
  });
  test("free text is scanned for hints", () => {
    const d = detectFromText("A headless FastAPI microservice exposing a REST API, deployed on Kubernetes.");
    expect(d.stacks).toEqual(["python"]);
    expect(d.has_ui).toBe(false);
    expect(d.deployment).toBe("kubernetes");
    expect(d.project_type).toBe("api-service");
  });
});

describe("tailoring rules", () => {
  test("python CLI with no UI and no deployment", () => {
    const ctx = { ...defaultContext(), stacks: ["python" as const], has_ui: false, deployment: "none" as const, performance_tests: false };
    const plan = planTailoring(ctx, DIALECTS);
    expect(plan.dialects).toEqual(["backend-python", "testing-integration", "testing-security", "testing-unit"]);
    expect(plan.exclude_agents).toEqual(["ux-ui-designer", "infrastructure-planner", "infrastructure-implementer", "solution-cartographer", "solution-inspector", "migrator"]);
    expect(plan.exclude_skills).toContain("spec-deploy");
  });
  test("web app keeps UI, fullstack, and devops", () => {
    const ctx = { ...defaultContext(), stacks: ["python" as const, "react" as const], existing_codebase: true, import_workflows: true };
    const plan = planTailoring(ctx, DIALECTS);
    expect(plan.dialects).toContain("fullstack-python");
    expect(plan.dialects).toContain("frontend-react");
    expect(plan.dialects).toContain("devops-cloud");
    expect(plan.dialects).not.toContain("backend-go");
    expect(plan.exclude_agents).toEqual([]);
  });
  test("unknown stack prunes no language dialect", () => {
    const plan = planTailoring(defaultContext(), DIALECTS);
    expect(plan.dialects).toContain("backend-go");
    expect(plan.dialects).toContain("backend-python");
  });
  test("registry rows of dropped dialects are removed", () => {
    const reg = "| Dialect | File |\n|--|--|\n| Backend Go | [[backend-go]] |\n| Backend Python | [[backend-python]] |\n\nSee [[api-standards]].";
    const out = pruneRegistry(reg, new Set(["backend-python"]));
    expect(out).not.toContain("backend-go");
    expect(out).toContain("[[backend-python]]");
    expect(out).toContain("[[api-standards]]");
  });
});

describe("limit detection", () => {
  const now = 1_800_000_000;
  const patterns = loadPatterns("/nonexistent", "claude");
  test("relative reset", () => {
    expect(parseReset("Rate limit hit. Try again in 2 hours 5 minutes.", now)).toBe(now + 7500);
    expect(parseReset("please retry in 30s", now)).toBe(now + 30);
  });
  test("epoch and retry-after", () => {
    expect(parseReset('{"resets_at": 1800003600}', now)).toBe(1_800_003_600);
    expect(parseReset("Claude usage limit reached|1800003600", now)).toBe(1_800_003_600);
    expect(parseReset("Retry-After: 90", now)).toBe(now + 90);
  });
  test("ISO timestamp", () => {
    expect(parseReset("limit resets 2027-01-15T10:00:00Z", now)).toBe(Date.parse("2027-01-15T10:00:00Z") / 1000);
  });
  test("clock time resolves to the next occurrence", () => {
    const r = parseReset("Your limit will reset at 3pm", now);
    expect(r).toBeDefined();
    expect((r as number) > now && (r as number) <= now + 86400).toBe(true);
    expect(new Date((r as number) * 1000).getHours()).toBe(15);
  });
  test("pattern hit with reset", () => {
    const hit = detectLimit(["working...", "Error: usage limit reached. Try again in 10 minutes"], 1, patterns, now);
    expect(hit).toEqual({ hit: true, source: "pattern", resetsAt: now + 600 });
  });
  test("structured hit needs a failure", () => {
    const ok = detectLimit(['{"type":"token_count","rate_limits":{"used_percent":40}}'], 0, patterns, now);
    expect(ok.hit).toBe(false);
    const bad = detectLimit(['{"type":"error","error":{"type":"rate_limit_error"},"resets_at":1800000900}'], 1, patterns, now);
    expect(bad).toEqual({ hit: true, source: "structured", resetsAt: 1_800_000_900 });
  });
  test("bare 429 counts only with a failing exit code", () => {
    expect(detectLimit(["HTTP 429"], 0, patterns, now).hit).toBe(false);
    expect(detectLimit(["HTTP 429"], 1, patterns, now).source).toBe("status");
  });
  test("ordinary failure is not a limit", () => {
    expect(detectLimit(["TypeError: x is not a function"], 1, patterns, now).hit).toBe(false);
  });
  test("session id is taken from output", () => {
    expect(sessionId(['{"session_id":"abc123-def"}', "done"])).toBe("abc123-def");
  });
});

describe("Claude Code limit message (real wording)", () => {
  const now = 1_791_400_000; // 2026-10-07T18:26:40Z
  const repoRoot = join(import.meta.dir, "..", ".."); // the shipped limit-patterns.json
  const patterns = loadPatterns(repoRoot, "claude");
  test("'session limit' is a limit, not just 'hit your limit'", () => {
    const real = JSON.stringify({ type: "assistant", apiError: "usage_limit_reached", message: { content: [{ type: "text", text: "You've hit your session limit · resets 10:50pm (Europe/Stockholm)" }] } });
    expect(detectLimit([real], 1, patterns, now).hit).toBe(true);
    expect(detectLimit(["You've hit your session limit · resets 10:50pm (Europe/Stockholm)"], 1, patterns, now).hit).toBe(true);
  });
  test("a rejected rate_limit_info counts without an error marker; an allowed one does not", () => {
    const rejected = JSON.stringify({ type: "rate_limit_event", rate_limit_info: { status: "rejected", resetsAt: now + 600 } });
    expect(detectLimit([rejected], 0, patterns, now)).toEqual({ hit: true, source: "structured", resetsAt: now + 600 });
    const allowed = JSON.stringify({ type: "rate_limit_event", rate_limit_info: { status: "allowed", resetsAt: now + 600 } });
    expect(detectLimit([allowed], 0, patterns, now).hit).toBe(false);
  });
  test("camelCase resetsAt epoch is read", () => {
    expect(parseReset('{"rate_limit_info":{"status":"rejected","resetsAt":1791492600}}', now)).toBe(1_791_492_600);
  });
  test("a clock time with a zone name is read in that zone, not the machine's", () => {
    const r = parseReset("You've hit your session limit · resets 10:50pm (Europe/Stockholm)", now) as number;
    // 22:50 in Stockholm (UTC+2 in October, before the 25th) is 20:50 UTC.
    expect(new Date(r * 1000).toISOString()).toBe("2026-10-07T20:50:00.000Z");
    expect(parseReset("resets 10:50pm (Europe/Stockholm)", Date.parse("2026-10-07T21:30:00Z") / 1000)).toBe(r + 86400);
  });
});

describe("transcript scan", () => {
  test("finds the last rejected limit and its reset", () => {
    const dir = mkdtempSync(join(tmpdir(), "kcc-tr-"));
    try {
      const file = join(dir, "s.jsonl");
      const limit = (resetsAt: number, ts: string): string =>
        JSON.stringify({ type: "assistant", sessionId: "sess-1", timestamp: ts, apiError: "usage_limit_reached", apiErrorParams: { rate_limit_info: { status: "rejected", resetsAt, rateLimitType: "five_hour" } } });
      writeFileSync(file, ["{not json", JSON.stringify({ type: "user" }), limit(1_791_000_000, "2026-10-04T10:00:00Z"), limit(1_791_492_600, "2026-10-08T17:49:32Z")].join("\n") + "\n");
      expect(scanTranscript(file)).toEqual({ at: Date.parse("2026-10-08T17:49:32Z") / 1000, resetsAt: 1_791_492_600, window: "five_hour", session: "sess-1", file });
      writeFileSync(file, JSON.stringify({ type: "user" }) + "\n");
      expect(scanTranscript(file)).toBeUndefined();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("mcp content", () => {
  const doc = "---\ntitle: X\n---\n# Doc\n\nintro\n\n## Hard stops\n\nstop 1\n\n### Detail\n\nd\n\n## Other `code`\n\nother\n";
  test("slug and headings skip frontmatter", () => {
    expect(slug("Other `code`")).toBe("other-code");
    expect(headings(doc).map((h) => h.title)).toEqual(["Doc", "Hard stops", "Detail", "Other `code`"]);
  });
  test("a section runs to the next heading of the same level", () => {
    const s = section(doc, "hard-stops") as string;
    expect(s).toContain("stop 1");
    expect(s).toContain("### Detail");
    expect(s).not.toContain("other");
    expect(section(doc, "Hard%20stops")).toBe(s);
    expect(section(doc, "missing")).toBeUndefined();
  });
  test("skill frontmatter", () => {
    const s = parseSkill("spec-plan", "---\nname: spec-plan\ndescription: >\n Plan a spec.\n Usage: /spec-plan SPEC-003\nargument-placeholder: <ARGS>\n---\n\n# Spec Plan\n\nPlan <ARGS>.\n");
    expect(s.description).toBe("Plan a spec. Usage: /spec-plan SPEC-003");
    expect(s.body).toContain("Plan <ARGS>.");
    expect(s.placeholder).toBe("<ARGS>");
  });
});
