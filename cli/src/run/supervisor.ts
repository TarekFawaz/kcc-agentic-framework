import { spawn } from "node:child_process";
import { join } from "node:path";
import { UsageError, workspace } from "../args";
import { readJson, writeJson } from "../fsutil";
import { isWindows, runTool } from "../platform";
import { readSettings } from "../settings";
import { detectLimit, latestTranscriptLimit, loadPatterns, sessionId } from "./limits";

const RESUME_PROMPT = "Read coordination/checkpoints/latest.md and continue the KCC run from next_action.";
const BYPASS = /dangerously|bypassPermissions|--yolo|skip-permissions/i;

export interface LimitRecord {
  harness: string;
  source: string;
  at: number;
  resets_at: number | null;
  resume_at: number | null;
  resumes: number;
  status: "waiting" | "resumed" | "gave-up";
}

export function limitFile(root: string): string {
  return join(root, "coordination", "run", "limit.json");
}

function quote(arg: string): string {
  if (/^[A-Za-z0-9_\-.:\\/=@%+,]+$/.test(arg)) return arg;
  return isWindows ? `"${arg.replace(/"/g, '\\"')}"` : `'${arg.replace(/'/g, `'\\''`)}'`;
}

function clock(epoch: number): string {
  return new Date(epoch * 1000).toLocaleString();
}

/** Runs a command line through the OS shell, echoing output and keeping the tail. */
function runStreaming(commandLine: string, cwd: string): Promise<{ status: number; lines: string[] }> {
  return new Promise((done) => {
    const lines: string[] = [];
    const child = spawn(commandLine, { cwd, shell: true, stdio: ["inherit", "pipe", "pipe"] });
    const collect = (chunk: Buffer, out: NodeJS.WriteStream): void => {
      out.write(chunk);
      for (const l of chunk.toString("utf8").split(/\r?\n/)) if (l) lines.push(l);
      if (lines.length > 400) lines.splice(0, lines.length - 400);
    };
    child.stdout?.on("data", (c: Buffer) => collect(c, process.stdout));
    child.stderr?.on("data", (c: Buffer) => collect(c, process.stderr));
    child.on("error", (e) => {
      lines.push(String(e.message));
      done({ status: 127, lines });
    });
    child.on("close", (code) => done({ status: code ?? 1, lines }));
  });
}

async function waitUntil(epoch: number): Promise<void> {
  for (;;) {
    const left = epoch - Math.floor(Date.now() / 1000);
    if (left <= 0) return;
    await Bun.sleep(Math.min(left, 60) * 1000);
  }
}

interface Policy {
  harness: string;
  grace: number;
  defaultWait: number;
  maxResumes: number;
}

function policy(root: string, harness: string | undefined, maxResumes: string | undefined): Policy {
  const s = readSettings(root);
  const c = s?.continuity ?? {};
  return {
    harness: harness ?? s?.run?.harness ?? "claude",
    grace: c.resume_grace_seconds ?? 120,
    defaultWait: (c.default_wait_minutes ?? 300) * 60,
    maxResumes: maxResumes !== undefined ? Number(maxResumes) : (c.max_resumes ?? 5),
  };
}

/** Records the limit, waits for the reset, and reports whether another attempt is allowed. */
async function holdForReset(root: string, p: Policy, source: string, resetsAt: number | undefined, resumes: number): Promise<boolean> {
  const now = Math.floor(Date.now() / 1000);
  const rec: LimitRecord = { harness: p.harness, source, at: now, resets_at: resetsAt ?? null, resume_at: null, resumes, status: "gave-up" };
  if (resumes >= p.maxResumes) {
    writeJson(limitFile(root), rec);
    console.error(`kcc: usage limit reached again and max_resumes (${p.maxResumes}) is used up. Continue later with: kcc run --resume`);
    return false;
  }
  const resumeAt = (resetsAt ?? now + p.defaultWait) + p.grace;
  writeJson(limitFile(root), { ...rec, resume_at: resumeAt, status: "waiting" });
  const why = resetsAt ? `reset at ${clock(resetsAt)}` : `no reset time in the output, using default_wait_minutes`;
  console.error(`kcc: usage limit reached on ${p.harness} (${why}). Resuming at ${clock(resumeAt)} (attempt ${resumes + 1} of ${p.maxResumes}). Ctrl+C stops the wait; continue later with: kcc run --resume`);
  await waitUntil(resumeAt);
  writeJson(limitFile(root), { ...rec, resume_at: resumeAt, resumes: resumes + 1, status: "resumed" });
  return true;
}

/** Supervises the vendored `kcc-run` driver: on exit 5 (usage limit) it waits and resumes. */
async function superviseDriver(root: string, args: string[], p: Policy, wait: boolean): Promise<number> {
  let current = args;
  for (let resumes = 0; ; resumes++) {
    const r = runTool(root, "kcc-run", current, { env: wait ? { KCC_SUPERVISED: "1" } : {} });
    if (r.stderr) console.error(r.stderr);
    if (r.status !== 5 || !wait) return r.status;
    const rec = readJson<{ resets_at?: number | null }>(limitFile(root));
    if (!(await holdForReset(root, p, "kcc-run", rec?.resets_at ?? undefined, resumes))) return 5;
    current = ["--resume", "--repo-root", root];
  }
}

function resumeCommand(root: string, p: Policy, original: string[], lines: string[]): string {
  const c = readSettings(root)?.continuity ?? {};
  const sid = sessionId(lines);
  let tpl = c.resume?.[p.harness] ?? null;
  if (!tpl || (tpl.includes("{session_id}") && !sid)) tpl = c.start?.[p.harness] ?? null;
  if (!tpl) tpl = '{command} "{resume_prompt}"';
  if (BYPASS.test(tpl)) throw new UsageError(`the resume template for '${p.harness}' uses a permission-bypass flag; KCC will not run it. Edit continuity in .KCC/settings.json.`);
  return tpl
    .replaceAll("{session_id}", sid ?? "")
    .replaceAll("{permission_mode}", c.permission_mode ?? "acceptEdits")
    .replaceAll("{resume_prompt}", RESUME_PROMPT)
    .replaceAll("{command}", quote(original[0] ?? p.harness));
}

/** Supervises any harness command: detects a limit in its output, waits, resumes. */
async function superviseWrapped(root: string, command: string[], p: Policy, wait: boolean): Promise<number> {
  const patterns = loadPatterns(root, p.harness);
  if (wait) resumeCommand(root, p, command, []); // refuse a bypass template before any work or waiting
  let line = command.map(quote).join(" ");
  for (let resumes = 0; ; resumes++) {
    const r = await runStreaming(line, root);
    const hit = detectLimit(r.lines, r.status, patterns);
    if (!hit.hit) return r.status;
    const cp = runTool(root, "kcc-checkpoint", ["--reason", "limit-hard", "--harness", p.harness, "--next-action", "Resume the interrupted harness session", "--repo-root", root], { capture: true });
    if (cp.status !== 0) console.error(`kcc: warning: kcc-checkpoint exited ${cp.status}`);
    if (!wait) {
      writeJson(limitFile(root), { harness: p.harness, source: hit.source, at: Math.floor(Date.now() / 1000), resets_at: hit.resetsAt ?? null, resume_at: null, resumes, status: "gave-up" } satisfies LimitRecord);
      return 5;
    }
    if (!(await holdForReset(root, p, hit.source, hit.resetsAt, resumes))) return 5;
    line = resumeCommand(root, p, command, r.lines);
  }
}

export async function run(argv: string[]): Promise<number> {
  // Own flags are taken out by hand: everything else belongs to kcc-run or the wrapped command.
  const sep = argv.indexOf("--");
  const own = sep >= 0 ? argv.slice(0, sep) : argv;
  const wrapped = sep >= 0 ? argv.slice(sep + 1) : [];
  const rest: string[] = [];
  let dir: string | undefined;
  let harness: string | undefined;
  let maxResumes: string | undefined;
  let wrap = false;
  let wait = true;
  for (let i = 0; i < own.length; i++) {
    const a = own[i] ?? "";
    if (a === "--wrap") wrap = true;
    else if (a === "--no-wait") wait = false;
    else if (a === "--dir") dir = own[++i];
    else if (a === "--max-resumes") maxResumes = own[++i];
    else if (a === "--harness") {
      harness = own[++i];
      if (harness) rest.push("--harness", harness);
    } else rest.push(a);
  }
  const root = workspace(dir);
  const p = policy(root, harness, maxResumes);
  if (!Number.isInteger(p.maxResumes) || p.maxResumes < 0) throw new UsageError("--max-resumes expects a whole number");

  if (wrap) {
    if (!wrapped.length) throw new UsageError("usage: kcc run --wrap [--harness <name>] -- <harness command...>");
    return superviseWrapped(root, wrapped, p, wait);
  }
  if (!rest.includes("--repo-root")) rest.push("--repo-root", root);
  // A dry run or a status query never waits.
  const passive = rest.includes("--dry-run") || rest.includes("--help") || rest.includes("-h");
  return superviseDriver(root, rest, p, wait && !passive);
}

export function limits(argv: string[]): number {
  const json = argv.includes("--json");
  const i = argv.indexOf("--dir");
  const root = workspace(i >= 0 ? argv[i + 1] : undefined);
  const usage = readJson<Record<string, unknown>>(join(root, "coordination", "usage.json"));
  const last = readJson<LimitRecord>(limitFile(root));
  const runState = readJson<{ status?: string; reason?: string }>(join(root, "coordination", "run", "run.json"));
  if (json) {
    console.log(JSON.stringify({ usage: usage ?? null, last_limit: last ?? null, run: runState ?? null }, null, 2));
    return 0;
  }
  const win = (name: string): string => {
    const w = usage?.[name] as { pct?: number; resets_at?: number | null } | undefined;
    if (!w || w.pct === undefined || w.pct === null) return "unknown";
    return `${w.pct}%${w.resets_at ? `, resets ${clock(w.resets_at)}` : ""}`;
  };
  console.log("Usage (Claude Code status line; other harnesses do not report usage):");
  if (usage) console.log(`  5-hour window: ${win("five_hour")}\n  7-day window:  ${win("seven_day")}`);
  else {
    console.log("  no percentages: coordination/usage.json is written only by the Claude Code status line,");
    console.log("  which the VS Code extension and `claude -p` do not run. A limit that is hit is still caught");
    console.log("  by the StopFailure hook (kcc-limit-hook), which reads the reset time from the session transcript.");
  }
  const seen = latestTranscriptLimit(root);
  if (seen) {
    const live = seen.resetsAt !== undefined && seen.resetsAt * 1000 > Date.now();
    const reset = seen.resetsAt ? `reset ${clock(seen.resetsAt)}${live ? " (still blocked)" : " (already reset)"}` : "reset not stated";
    console.log(`Claude session transcripts: last limit message ${seen.at ? clock(seen.at) : "(time unknown)"}${seen.window ? `, ${seen.window} window` : ""}, ${reset}`);
  }
  console.log("Last limit:");
  if (!last) console.log("  none recorded");
  else {
    console.log(`  harness ${last.harness}, detected by ${last.source} at ${clock(last.at)}`);
    console.log(`  reset: ${last.resets_at ? clock(last.resets_at) : "not stated"} | status: ${last.status}${last.resume_at && last.status === "waiting" ? `, resuming ${clock(last.resume_at)}` : ""} | resumes used: ${last.resumes}`);
  }
  console.log(`Run: ${runState?.status ?? "no run recorded"}${runState?.reason ? ` (${runState.reason})` : ""}`);
  return 0;
}
