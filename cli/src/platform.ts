import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

export const isWindows = process.platform === "win32";

export function which(cmd: string): string | undefined {
  const r = spawnSync(isWindows ? "where" : "which", [cmd], { encoding: "utf8" });
  if (r.status !== 0) return undefined;
  return r.stdout.split(/\r?\n/).find((l) => l.trim())?.trim();
}

/** Windows PowerShell 5.1 ships with the OS; pwsh is the fallback. */
export function powershellExe(): string | undefined {
  for (const c of ["powershell.exe", "pwsh.exe", "pwsh"]) if (which(c)) return c;
  return undefined;
}

/** `--repo-root` -> `-RepoRoot`. Values and positionals pass through. */
export function toPowerShellArgs(args: string[]): string[] {
  return args.map((a) => {
    if (!/^--[a-z][a-z0-9-]*$/.test(a)) return a;
    return "-" + a.slice(2).split("-").map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join("");
  });
}

/** `-RepoRoot` -> `--repo-root`, so either spelling works on either OS. */
export function toBashArgs(args: string[]): string[] {
  return args.map((a) => {
    if (!/^-[A-Z][A-Za-z0-9]*$/.test(a)) return a;
    return "--" + a.slice(1).replace(/[A-Z]/g, (c, i: number) => (i ? "-" : "") + c.toLowerCase());
  });
}

/** Walks up from `start` to the folder that holds `.KCC/`. */
export function findRoot(start: string): string | undefined {
  let dir = resolve(start);
  for (;;) {
    if (existsSync(join(dir, ".KCC", "kernel"))) return dir;
    const parent = resolve(dir, "..");
    if (parent === dir) return undefined;
    dir = parent;
  }
}

export interface ToolRun {
  status: number;
  stdout: string;
  stderr: string;
}

export interface ToolOptions {
  capture?: boolean;
  env?: Record<string, string>;
  input?: string;
}

/**
 * Runs a vendored `.KCC/tools/<name>` script with the shell the OS already
 * has: PowerShell on Windows, bash elsewhere. Flags are accepted in bash
 * spelling (`--repo-root`) and translated for PowerShell.
 */
export function runTool(root: string, name: string, args: string[], opts: ToolOptions = {}): ToolRun {
  const tools = join(root, ".KCC", "tools");
  const stdio = opts.capture ? "pipe" : "inherit";
  const env = { ...process.env, ...opts.env };
  let r: SpawnSyncReturns<string>;
  if (isWindows) {
    const ps = powershellExe();
    const script = join(tools, `${name}.ps1`);
    if (!ps) return { status: 2, stdout: "", stderr: "kcc: PowerShell was not found on this machine" };
    if (!existsSync(script)) return { status: 2, stdout: "", stderr: `kcc: ${script} not found (run 'kcc init' or 'kcc upgrade')` };
    r = spawnSync(ps, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, ...toPowerShellArgs(args)], {
      cwd: root, stdio, env, encoding: "utf8", input: opts.input, maxBuffer: 64 * 1024 * 1024,
    });
  } else {
    const script = join(tools, `${name}.sh`);
    if (!existsSync(script)) return { status: 2, stdout: "", stderr: `kcc: ${script} not found (run 'kcc init' or 'kcc upgrade')` };
    r = spawnSync("bash", [script, ...toBashArgs(args)], {
      cwd: root, stdio, env, encoding: "utf8", input: opts.input, maxBuffer: 64 * 1024 * 1024,
    });
  }
  if (r.error) return { status: 2, stdout: "", stderr: `kcc: could not start ${name}: ${r.error.message}` };
  return { status: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}
