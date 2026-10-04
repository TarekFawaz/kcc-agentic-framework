import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

/** sha256 with CRLF folded to LF, so a git autocrlf checkout is not seen as an edit. */
export function contentHash(data: Buffer | string): string {
  const buf = typeof data === "string" ? Buffer.from(data, "utf8") : data;
  const lf = buf.includes(13) ? Buffer.from(buf.toString("latin1").replace(/\r\n/g, "\n"), "latin1") : buf;
  return createHash("sha256").update(lf).digest("hex");
}

export function fileHash(path: string): string | undefined {
  return existsSync(path) ? contentHash(readFileSync(path)) : undefined;
}

export function writeFileEnsured(path: string, data: Buffer | string, executable = false): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
  if (executable && process.platform !== "win32") chmodSync(path, 0o755);
}

export function moveFile(from: string, to: string): void {
  mkdirSync(dirname(to), { recursive: true });
  rmSync(to, { force: true });
  renameSync(from, to);
}

export function readJson<T>(path: string): T | undefined {
  if (!existsSync(path)) return undefined;
  try {
    return JSON.parse(readFileSync(path, "utf8").replace(/^﻿/, "")) as T;
  } catch {
    return undefined;
  }
}

export function writeJson(path: string, value: unknown): void {
  writeFileEnsured(path, JSON.stringify(value, null, 2) + "\n");
}

/** Relative paths (forward slashes) of every file under `dir`. */
export function listFiles(dir: string, prefix = ""): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const name of readdirSync(dir).sort()) {
    const full = join(dir, name);
    const rel = prefix ? `${prefix}/${name}` : name;
    if (statSync(full).isDirectory()) out.push(...listFiles(full, rel));
    else out.push(rel);
  }
  return out;
}
