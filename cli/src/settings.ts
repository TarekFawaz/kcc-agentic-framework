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
