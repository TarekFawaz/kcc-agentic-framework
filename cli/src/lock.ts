import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { contentHash, fileHash, readJson, writeFileEnsured, writeJson } from "./fsutil";
import { isExecutable, isUserOwned, payloadFiles, payloadVersion } from "./payload";
import { CLI_VERSION } from "./version";

export interface Lock {
  schema: 1;
  cli_version: string;
  payload_version: string;
  updated_at: string;
  /** Hash of each framework file as shipped, keyed by path relative to `.KCC/`. */
  files: Record<string, string>;
  /** Hash of files the CLI rewrote on purpose (tailoring), so they are not reported as local edits. */
  derived: Record<string, string>;
}

export const TAILORED_OUT = ".tailored-out";

export function kccDir(root: string): string {
  return join(root, ".KCC");
}

// On disk each entry is one "<sha256> <path>" string (the sha256sum layout).
// A `"path": "hash"` mapping makes secret scanners flag paths such as
// token-guard.md as a key with a high-entropy value.
type StoredLock = Omit<Lock, "files" | "derived"> & { files: string[]; derived: string[] };

function toMap(list: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (!Array.isArray(list)) return out;
  for (const item of list) {
    const s = String(item);
    const i = s.indexOf(" ");
    if (i > 0) out[s.slice(i + 1)] = s.slice(0, i);
  }
  return out;
}

const toList = (map: Record<string, string>): string[] => Object.keys(map).sort().map((rel) => `${map[rel]} ${rel}`);

export function readLock(root: string): Lock | undefined {
  const stored = readJson<StoredLock>(join(kccDir(root), "kcc.lock"));
  if (!stored) return undefined;
  return { ...stored, files: toMap(stored.files), derived: toMap(stored.derived) };
}

export function writeLock(root: string, lock: Lock): void {
  const stored: StoredLock = { ...lock, files: toList(lock.files), derived: toList(lock.derived) };
  writeJson(join(kccDir(root), "kcc.lock"), stored);
}

/** Paths (relative to `.KCC/`) that tailoring moved aside. */
export function readExcludes(root: string): Set<string> {
  const path = join(kccDir(root), "tailoring.exclude");
  const set = new Set<string>();
  if (!existsSync(path)) return set;
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const t = line.trim();
    if (t && !t.startsWith("#")) set.add(t);
  }
  return set;
}

export interface ApplyResult {
  written: string[];
  unchanged: string[];
  conflicts: string[];
  removed: string[];
  keptRemoved: string[];
}

/**
 * Brings `.KCC/` in line with the embedded payload.
 * A file is overwritten only when it still matches what a previous install
 * wrote; anything edited locally is reported as a conflict and left alone
 * unless `force` is set.
 */
export function applyPayload(root: string, opts: { force?: boolean; dryRun?: boolean } = {}): ApplyResult {
  const dir = kccDir(root);
  const old = readLock(root);
  const excludes = readExcludes(root);
  const files = payloadFiles();
  const res: ApplyResult = { written: [], unchanged: [], conflicts: [], removed: [], keptRemoved: [] };
  const next: Lock = {
    schema: 1,
    cli_version: CLI_VERSION,
    payload_version: payloadVersion,
    updated_at: new Date().toISOString(),
    files: {},
    derived: old?.derived ?? {},
  };

  for (const [rel, data] of files) {
    const target = excludes.has(rel) ? join(dir, TAILORED_OUT, rel) : join(dir, rel);
    const newHash = contentHash(data);
    const local = fileHash(target);
    if (isUserOwned(rel)) {
      if (local === undefined) {
        if (!opts.dryRun) writeFileEnsured(target, data);
        res.written.push(rel);
      } else res.unchanged.push(rel);
      continue;
    }
    const pristine = local === undefined || local === old?.files[rel] || local === old?.derived[rel];
    if (local === newHash) {
      res.unchanged.push(rel);
      next.files[rel] = newHash;
    } else if (pristine || opts.force) {
      if (!opts.dryRun) writeFileEnsured(target, data, isExecutable(rel));
      res.written.push(rel);
      next.files[rel] = newHash;
      delete next.derived[rel];
    } else {
      res.conflicts.push(rel);
      if (old?.files[rel]) next.files[rel] = old.files[rel];
    }
  }

  // Files a previous version shipped and this one dropped.
  for (const [rel, hash] of Object.entries(old?.files ?? {})) {
    if (files.has(rel)) continue;
    const target = join(dir, rel);
    const local = fileHash(target);
    if (local === undefined) continue;
    if (local === hash || opts.force) {
      if (!opts.dryRun) rmSync(target, { force: true });
      res.removed.push(rel);
    } else res.keptRemoved.push(rel);
  }

  if (!opts.dryRun) writeLock(root, next);
  return res;
}

export interface Drift {
  missing: string[];
  modified: string[];
}

/** Compares `.KCC/` with the lock file. */
export function drift(root: string): Drift {
  const lock = readLock(root);
  const excludes = readExcludes(root);
  const out: Drift = { missing: [], modified: [] };
  if (!lock) return out;
  for (const [rel, hash] of Object.entries(lock.files)) {
    if (excludes.has(rel)) continue;
    const local = fileHash(join(kccDir(root), rel));
    if (local === undefined) out.missing.push(rel);
    else if (local !== hash && local !== lock.derived[rel]) out.modified.push(rel);
  }
  return out;
}
