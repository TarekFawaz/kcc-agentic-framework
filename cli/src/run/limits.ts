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
    structuredKeys: Array.isArray(keys) ? keys.map(String) : ["rate_limit_error", "rate_limits", "rate_limit", "resets_at", "reset_at", "retry_after", "usage_limit"],
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
      const d = new Date(now * 1000);
      d.setHours(hour, Number(m[3] ?? 0), 0, 0);
      if (d.getTime() / 1000 <= now) d.setDate(d.getDate() + 1);
      return Math.floor(d.getTime() / 1000);
    }
  }
  return undefined;
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
      if (failing && (status || findKey(obj, patterns.structuredKeys))) hit = { hit: true, source: "structured" };
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
