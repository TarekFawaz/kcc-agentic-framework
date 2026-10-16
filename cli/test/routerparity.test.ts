import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { route, type Effort, type Task, type Tier } from "../src/run/router";
import { securityHit } from "../src/run/routing";

// The router has one reference (router.ts, used by `kcc route`) and two ports that every flow calls before it spawns an
// agent (kcc-route.ps1, kcc-route.sh). They must give the same answer for the same signals.
setDefaultTimeout(180000);
const tools = join(import.meta.dir, "..", "..", ".KCC", "tools");

const TIERS: Tier[] = ["fast", "balanced", "strong"];
const EFFORTS: Effort[] = ["low", "medium", "high", "xhigh", "max"];
const TASKS: Task[] = ["research", "architecture", "security", "spec", "plan", "implement", "review", "docs"];
const DOMAINS = [undefined, "novel", "common"] as const;
const COMPLEXITIES = [undefined, "low", "high", "extra-high"] as const;
const SIZES: [number, number][] = [[0, 0], [4, 0], [0, 6], [2, 3]];

interface Row { t: Tier; e: Effort; task: Task; domain?: "novel" | "common"; risk: boolean; cx?: "low" | "high" | "extra-high"; items: number; files: number; attempt: number; budget?: number; cap?: Tier; capEffort?: Effort }

// A deterministic spread over the signal space (a full product is tens of thousands of rows).
function rows(): Row[] {
  const out: Row[] = [];
  let seed = 12345;
  const pick = <T>(a: readonly T[]): T => a[((seed = (seed * 1103515245 + 12345) & 0x7fffffff) >>> 8) % a.length]!;
  for (let i = 0; i < 400; i++) {
    const [items, files] = pick(SIZES);
    out.push({ t: pick(TIERS), e: pick(EFFORTS), task: pick(TASKS), domain: pick(DOMAINS) as Row["domain"], risk: pick([false, true]), cx: pick(COMPLEXITIES) as Row["cx"], items, files, attempt: pick([1, 2, 3]), budget: pick([undefined, 10, 50]), cap: pick([undefined, "balanced"] as const), capEffort: pick([undefined, undefined, "high"] as const) });
  }
  return out;
}
const line = (r: Row): string => [r.t, r.e, r.task, r.domain ?? "-", r.risk ? 1 : 0, r.cx ?? "-", r.items, r.files, r.attempt, r.budget ?? "-", r.cap ?? "-", r.capEffort ?? "-"].join(" ");

describe("router parity: router.ts, kcc-route.ps1, kcc-route.sh", () => {
  const all = rows();
  const input = all.map(line).join(String.fromCharCode(10)) + String.fromCharCode(10);
  const expected = all.map((r) => {
    const x = route({ defaultTier: r.t, defaultEffort: r.e, task: r.task, domain: r.domain, risk: r.risk, complexity: r.cx, items: r.items, files: r.files, attempt: r.attempt, budgetLeftPct: r.budget, maxTier: r.cap, maxEffort: r.capEffort });
    return `${x.tier} ${x.effort}`;
  });

  test("the reference is not degenerate: the rows reach every tier and effort the rules can give", () => {
    expect(new Set(expected.map((l) => l.split(" ")[0]))).toEqual(new Set(["fast", "balanced", "strong"]));
    expect(new Set(expected.map((l) => l.split(" ")[1]))).toEqual(new Set(["low", "medium", "high", "xhigh"]));
  });

  test("bash gives the reference's tier and effort for every row", () => {
    const r = spawnSync("bash", [join(tools, "kcc-route.sh"), "--batch"], { input, encoding: "utf8" });
    expect(r.stdout.trim().split(/\r?\n/)).toEqual(expected);
  });

  test("PowerShell gives the reference's tier and effort for every row", () => {
    if (process.platform !== "win32") return;
    const r = spawnSync("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(tools, "kcc-route.ps1"), "-Batch"], { input, encoding: "utf8" });
    expect(r.stdout.trim().split(/\r?\n/)).toEqual(expected);
  });

  test("the security words are found the same way, in the same order", () => {
    const texts = [
      "login with a password", "show the list of accounts", "stores sessions and tokens", "CSRF protection for forms", "encrypted at rest",
      "ledger and budgets", "handles personal data of users", "OAuth sign in", "payments over the API", "a scaffold with lint and tests", "JWTs are rotated",
    ];
    const ref = texts.map((t) => securityHit(t) ?? "");
    const bash = texts.map((t) => spawnSync("bash", [join(tools, "kcc-route.sh"), "--scan-text", t], { encoding: "utf8" }).stdout.trim());
    expect(bash).toEqual(ref);
    if (process.platform === "win32") {
      const ps = texts.map((t) => spawnSync("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(tools, "kcc-route.ps1"), "-ScanText", t], { encoding: "utf8" }).stdout.trim());
      expect(ps).toEqual(ref);
    }
  });
});
