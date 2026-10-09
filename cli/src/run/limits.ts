import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readJson } from "../fsutil";

/** Built-in copy of `.KCC/kernel/limit-patterns.json`, used when the workspace has none. */
const DEFAULT_LIMIT_REGEX =
  "usage limit|rate limit|rate-limit|ratelimit|limit reached|quota exceeded|exceeded your (current )?quota|too many requests|resource_exhausted|limit exceeded";

interface PatternFile {
  [key: string]: unknown;
}

export interface LimitPatterns {
  regex: RegExp;
  /** JSON keys that mark a rate-limit event in a harness's structured output. */
  structuredKeys: string[];
}

export function loadPatterns(root: string, harness: string): LimitPatterns {
  const file = readJson<PatternFile>(join(root, ".KCC", "kernel", "limit-patterns.json")) ?? {};
  const parts = [file["limit_regex.default"], file[`limit_regex.${harness}`]].filter((p): p is string => typeof p === "string" && p !== "");
  const source = parts.length ? parts.join("|") : DEFAULT_LIMIT_REGEX;
  const keys = file["structured_keys"];
  return {
    regex: new RegExp(source, "i"),
    structuredKeys: Array.isArray(keys) ? keys.map(String) : ["usage_limit_reached", "rate_limit_error", "rate_limits", "rate_limit", "resets_at", "reset_at", "retry_after", "usage_limit"],
  };
}

export interface LimitHit {
  hit: boolean;
  source: "structured" | "pattern" | "status" | "none";
  /** Unix seconds when the limit resets, if the output said so. */
  resetsAt?: number;
}

const UNIT_SECONDS: [RegExp, number][] = [
  [/^(h|hr|hrs|hour|hours)$/, 3600],
  [/^(m|min|mins|minute|minutes)$/, 60],
  [/^(s|sec|secs|second|seconds)$/, 1],
];

/**
 * Next occurrence of a wall-clock time in an IANA zone, as epoch seconds. Claude Code words its
 * limit message "resets 10:50pm (Europe/Stockholm)", and that zone is not always this machine's.
 */
function zonedNext(hour: number, minute: number, zone: string, now: number): number | undefined {
  try {
    const fmt = new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
    const o: Record<string, number> = {};
    for (const p of fmt.formatToParts(new Date(now * 1000))) if (p.type !== "literal") o[p.type] = Number(p.value);
    const offsetMs = Date.UTC(o.year!, o.month! - 1, o.day!, o.hour!, o.minute!, o.second!) - now * 1000;
    let epoch = (Date.UTC(o.year!, o.month! - 1, o.day!, hour, minute, 0) - offsetMs) / 1000;
    if (epoch <= now) epoch += 86400;
    return Math.floor(epoch);
  } catch {
    return undefined; // unknown zone name
  }
}

/** Reset time from one line of harness output. Same formats as kcc-run and kcc-limit-watch. */
export function parseReset(line: string, now: number): number | undefined {
  const t = line.toLowerCase();
  let m = /\|(\d{10})/.exec(t) ?? /"?resets?_?at"?[: =]+"?(\d{10})/.exec(t);
  if (m) return Number(m[1]);
  m = /retry[-_]after"?:? *"?(\d+)/.exec(t);
  if (m) return now + Number(m[1]);
  m = /(again|retry|resets?|available|wait)[a-z ]* in ([0-9][0-9a-z .,]*)/.exec(t);
  if (m) {
    let total = 0;
    for (const part of (m[2] ?? "").matchAll(/(\d+(?:\.\d+)?)\s*([a-z]+)/g)) {
      const unit = UNIT_SECONDS.find(([re]) => re.test(part[2] ?? ""));
      if (unit) total += Number(part[1]) * unit[1];
      else if (part[2] !== "and") break;
    }
    if (total > 0) return now + Math.round(total);
  }
  const iso = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?/.exec(line);
  if (iso) {
    const hasZone = iso[2] !== undefined;
    const ms = Date.parse(hasZone ? iso[0].replace(" ", "T") : iso[0].replace(" ", "T") + "Z");
    if (!Number.isNaN(ms)) return Math.floor(ms / 1000);
  }
  // "resets at 3pm", "try again at 14:30": the next such local time.
  m = /(again|resets?|available)[a-z ]* (?:at )?(\d{1,2})(?::(\d{2}))? *(am|pm)?(?![0-9a-z])/.exec(t);
  if (m && (m[4] || m[3] || / at /.test(m[0]))) {
    let hour = Number(m[2]);
    if (m[4] === "pm" && hour < 12) hour += 12;
    if (m[4] === "am" && hour === 12) hour = 0;
    if (hour < 24) {
      const zone = /\(([a-z_]+\/[a-z_+-]+(?:\/[a-z_+-]+)?)\)/i.exec(line)?.[1];
      const zoned = zone ? zonedNext(hour, Number(m[3] ?? 0), zone, now) : undefined;
      if (zoned !== undefined) return zoned;
      const d = new Date(now * 1000);
      d.setHours(hour, Number(m[3] ?? 0), 0, 0);
      if (d.getTime() / 1000 <= now) d.setDate(d.getDate() + 1);
      return Math.floor(d.getTime() / 1000);
    }
  }
  return undefined;
}

/** True when a Claude Code rate_limit_info object says the request was rejected. */
function findRejected(value: unknown, depth = 0): boolean {
  if (depth > 6 || value === null || typeof value !== "object") return false;
  const o = value as Record<string, unknown>;
  const info = o.rate_limit_info as { status?: unknown } | undefined;
  if (info && typeof info === "object" && info.status === "rejected") return true;
  return Object.values(o).some((v) => findRejected(v, depth + 1));
}

function findKey(value: unknown, keys: string[], depth = 0): boolean {
  if (depth > 6 || value === null || typeof value !== "object") {
    return typeof value === "string" && keys.includes(value);
  }
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    if (keys.includes(k) && v !== null && v !== false) return true;
    if (findKey(v, keys, depth + 1)) return true;
  }
  return false;
}

/**
 * Decides whether the harness stopped on a usage or rate limit.
 * Layer 1: a JSON line that carries a rate-limit key or a 429 status.
 * Layer 2: the pattern table. A bare "429" counts only with a failing exit code.
 */
export function detectLimit(lines: string[], exitCode: number, patterns: LimitPatterns, now = Math.floor(Date.now() / 1000)): LimitHit {
  const tail = lines.slice(-80);
  let hit: LimitHit = { hit: false, source: "none" };
  for (const line of tail) {
    const s = line.trim();
    if (!s.startsWith("{")) continue;
    try {
      const obj = JSON.parse(s) as Record<string, unknown>;
      const failing = exitCode !== 0 || obj.is_error === true || obj.type === "error" || obj.error !== undefined;
      const status = obj.status === 429 || (obj.error as { status?: number } | undefined)?.status === 429;
      // A rejected rate_limit_info is a limit even on a line that is not marked as an error.
      if ((failing && (status || findKey(obj, patterns.structuredKeys))) || findRejected(obj)) hit = { hit: true, source: "structured" };
    } catch {
      // not JSON after all
    }
  }
  if (!hit.hit) {
    const text = tail.slice(-60).join("\n");
    if (patterns.regex.test(text)) hit = { hit: true, source: "pattern" };
    else if (exitCode !== 0 && /(^|[^0-9])429([^0-9]|$)/.test(text)) hit = { hit: true, source: "status" };
  }
  if (hit.hit) {
    for (let i = tail.length - 1; i >= 0 && hit.resetsAt === undefined; i--) hit.resetsAt = parseReset(tail[i] ?? "", now);
  }
  return hit;
}

export function sessionId(lines: string[]): string | undefined {
  let found: string | undefined;
  for (const l of lines) {
    const m = /session[ _-]?id["']?\s*[:=]\s*["']?([A-Za-z0-9_.:-]{6,})/i.exec(l);
    if (m) found = m[1];
  }
  return found;
}

export interface TranscriptLimit {
  /** Unix seconds of the limit message. */
  at: number;
  resetsAt?: number;
  /** five_hour, seven_day, ... as Claude Code names the window. */
  window?: string;
  session?: string;
  file: string;
}

const TAIL_BYTES = 512 * 1024;

function tailText(file: string): string {
  const fd = openSync(file, "r");
  try {
    const size = fstatSync(fd).size;
    const len = Math.min(size, TAIL_BYTES);
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, size - len);
    return buf.toString("utf8");
  } finally {
    closeSync(fd);
  }
}

/** The last usage-limit message Claude Code recorded in one session transcript (JSONL). */
export function scanTranscript(file: string): TranscriptLimit | undefined {
  let found: TranscriptLimit | undefined;
  for (const line of tailText(file).split("\n")) {
    if (!line.includes("usage_limit_reached") && !line.includes('"rejected"')) continue;
    try {
      const o = JSON.parse(line) as { apiError?: string; timestamp?: string; sessionId?: string; apiErrorParams?: { rate_limit_info?: { status?: string; resetsAt?: number; rateLimitType?: string } } };
      const info = o.apiErrorParams?.rate_limit_info;
      if (o.apiError !== "usage_limit_reached" && info?.status !== "rejected") continue;
      const at = o.timestamp ? Math.floor(Date.parse(o.timestamp) / 1000) : 0;
      found = { at, resetsAt: info?.resetsAt, window: info?.rateLimitType, session: o.sessionId, file };
    } catch {
      // a partial first line of the tail, or not JSON
    }
  }
  return found;
}

/** Claude Code keeps transcripts under ~/.claude/projects/<path with every non-alphanumeric as ->. */
export function transcriptDir(root: string, home = homedir()): string | undefined {
  const base = join(home, ".claude", "projects");
  if (!existsSync(base)) return undefined;
  const slug = root.replace(/[^A-Za-z0-9]/g, "-").toLowerCase();
  const name = readdirSync(base).find((n) => n.toLowerCase() === slug);
  return name ? join(base, name) : undefined;
}

/** Newest usage-limit message in this workspace's recent Claude Code sessions. */
export function latestTranscriptLimit(root: string, home = homedir()): TranscriptLimit | undefined {
  const dir = transcriptDir(root, home);
  if (!dir) return undefined;
  const recent = readdirSync(dir)
    .filter((n) => n.endsWith(".jsonl"))
    .map((n) => ({ file: join(dir, n), mtime: statSync(join(dir, n)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, 5);
  // A limit often lands in a subagent's transcript first: <session-id>/subagents/agent-*.jsonl.
  const files = recent.map((r) => r.file);
  for (const { file } of recent) {
    const subDir = join(file.slice(0, -".jsonl".length), "subagents");
    if (!existsSync(subDir)) continue;
    files.push(
      ...readdirSync(subDir)
        .filter((n) => n.endsWith(".jsonl"))
        .map((n) => ({ file: join(subDir, n), mtime: statSync(join(subDir, n)).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime)
        .slice(0, 10)
        .map((r) => r.file),
    );
  }
  let best: TranscriptLimit | undefined;
  for (const file of files) {
    const hit = scanTranscript(file);
    if (hit && (!best || hit.at > best.at)) best = hit;
  }
  return best;
}
