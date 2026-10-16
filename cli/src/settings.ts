import { join } from "node:path";
import { readJson, writeJson } from "./fsutil";

export interface Tailoring {
  version: 1;
  applied_at: string;
  context: Record<string, unknown>;
  dialects: string[];
  exclude_agents: string[];
  exclude_skills: string[];
}

export interface Settings {
  [key: string]: unknown;
  repo?: { bootstrap?: string; decision?: string | null; remote?: string | null };
  quality?: { coverage_min_pct?: number; [key: string]: unknown };
  continuity?: {
    resume_grace_seconds?: number;
    default_wait_minutes?: number;
    max_resumes?: number;
    permission_mode?: string;
    resume?: Record<string, string | null>;
    start?: Record<string, string | null>;
  };
  run?: { harness?: string };
  tailoring?: Tailoring;
  mcp?: { registered?: boolean };
  notices?: Record<string, boolean>;
}

export function settingsPath(root: string): string {
  return join(root, ".KCC", "settings.json");
}

export function readSettings(root: string): Settings | undefined {
  return readJson<Settings>(settingsPath(root));
}

export function writeSettings(root: string, settings: Settings): void {
  writeJson(settingsPath(root), settings);
}

const isPlainObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/**
 * Copies keys that `template` has and `target` lacks, recursing into plain objects.
 * An existing value is never changed, so local settings always win.
 * Returns the dotted paths that were added.
 */
export function addMissingKeys(target: Record<string, unknown>, template: Record<string, unknown>, prefix = ""): string[] {
  const added: string[] = [];
  for (const [key, value] of Object.entries(template)) {
    if (key === "$schema") continue;
    const path = prefix ? `${prefix}.${key}` : key;
    if (!(key in target)) {
      target[key] = structuredClone(value);
      added.push(path);
    } else if (isPlainObject(target[key]) && isPlainObject(value)) {
      added.push(...addMissingKeys(target[key] as Record<string, unknown>, value, path));
    }
  }
  return added;
}

/** Adds settings keys a newer framework ships. Writes only when something was added (unless `dryRun`). */
export function migrateSettings(root: string, shipped: Buffer | undefined, dryRun = false): string[] {
  const current = readSettings(root);
  if (!current || !shipped) return [];
  let template: unknown;
  try {
    template = JSON.parse(shipped.toString("utf8").replace(/^﻿/, ""));
  } catch {
    return [];
  }
  if (!isPlainObject(template)) return [];
  const added = addMissingKeys(current, template);
  if (added.length && !dryRun) writeSettings(root, current);
  return added;
}
