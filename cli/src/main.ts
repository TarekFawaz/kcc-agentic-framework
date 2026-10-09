#!/usr/bin/env bun
import { HARNESSES, parse, target, UsageError, workspace } from "./args";
import { doctor } from "./commands/doctor";
import { hint } from "./commands/hint";
import { init } from "./commands/init";
import { runTailor } from "./commands/tailor";
import { upgrade } from "./commands/upgrade";
import { registerMcp } from "./mcp/register";
import { serveMcp } from "./mcp/server";
import { payloadVersion } from "./payload";
import { runTool } from "./platform";
import { limits, run } from "./run/supervisor";
import { CLI_VERSION } from "./version";

const HELP = `kcc ${CLI_VERSION} - the KCC spec-driven workflow framework

Usage: kcc <command> [options]

Set up
  init [harness] [--context <file> | --from-baseline] [--mcp] [--force]
                      Install .KCC/ into this folder and generate harness adapters.
                      harness: ${HARNESSES.join(" | ")} (default all)
  tailor [--context <file> | --from-baseline | --yes] [--dry-run] [--show] [--reset]
                      Fit agents, skills, and dialects to the solution.
  upgrade [--dry-run] [--force]
                      Refresh .KCC/ from this CLI version; local edits are kept.
  sync [harness]      Regenerate harness adapters from .KCC/.
  mcp [--register]    Serve KCC over MCP (stdio), or register the server with the harnesses.

Check
  doctor [--json] [--fix-hooks]
                      Check the installation; exit 1 when something must be fixed.
                      --fix-hooks adds missing KCC hooks to .claude/settings.json.
  validate [--mode cell|repo]
                      Run the framework validator.
  limits [--json]     Show usage, the last limit hit, and the next resume.

Steer
  hint "<text>" [--to all|main|subagents|<agent>] [--expires <minutes>]
                      Give the running session (and its subagents) a hint about behaviour or
                      expectations. Also: kcc --hint "<text>". Works while the session is busy.
  hint --list | --clear <H-NNN|all> | --pending [--for <agent>]
                      Show, withdraw, or read (hook-less harnesses) the active hints.

Run
  run --input <idea|path|IDEA-ID|SPEC-ID|all> [kcc-run options]
                      Drive the lifecycle; on a usage limit it waits and resumes.
  run --resume        Continue a suspended or paused run.
  run --wrap [--harness <name>] -- <command...>
                      Supervise any harness command the same way.
  tool <name> [args]  Run any tool from .KCC/tools (bash-style flags on every OS).

Target folder: every command works on the current folder by default.
  Give another one as a path (kcc init claude C:\\work\\app, kcc tailor ../app,
  kcc doctor ../app) or with --dir <path> (required form for run, limits, mcp, tool).
  init creates the folder if it does not exist.
Other options: --help, --version
Docs: docs/cli.md`;

async function main(argv: string[]): Promise<number> {
  const [first, ...rest] = argv;
  // `--Help` and `--VERSION` work too; command names stay lower-case.
  const cmd = first?.startsWith("-") ? first.toLowerCase() : first;
  // `kcc <command> --help` shows the usage. `run` and `tool` pass --help on to the script.
  if (cmd && !["run", "tool"].includes(cmd) && rest.some((a) => /^(--help|-h)$/i.test(a))) {
    console.log(HELP);
    return 0;
  }
  switch (cmd) {
    case undefined:
    case "help":
    case "--help":
    case "-h":
      console.log(HELP);
      return 0;
    case "version":
    case "--version":
    case "-v":
      console.log(`kcc ${CLI_VERSION} (framework ${payloadVersion})`);
      return 0;
    case "init":
      return init(rest);
    case "tailor":
      return runTailor(rest);
    case "upgrade":
      return upgrade(rest);
    case "doctor":
      return doctor(rest);
    case "limits":
      return limits(rest);
    case "hint":
    case "--hint":
      return hint(rest);
    case "run":
      return run(rest);
    case "sync": {
      const { positionals, values } = parse(rest, [], ["dir", "harness"]);
      const t = target(positionals, values.dir, true);
      const harness = (values.harness as string | undefined) ?? t.harness ?? "all";
      if (!HARNESSES.includes(harness)) throw new UsageError(`unknown harness '${harness}'. Use one of: ${HARNESSES.join(", ")}`);
      const root = workspace(t.dir);
      return runTool(root, "sync-adapters", ["--harness", harness, "--repo-root", root]).status;
    }
    case "validate": {
      const { positionals, values } = parse(rest, [], ["dir", "mode"]);
      const root = workspace(target(positionals, values.dir, false).dir);
      return runTool(root, "validate-kcc", ["--repo-root", root, ...(typeof values.mode === "string" ? ["--mode", values.mode] : [])]).status;
    }
    case "tool": {
      // `kcc tool --dir <path> <name> ...` targets another workspace.
      let toolDir: string | undefined;
      if (rest[0] === "--dir") toolDir = rest.splice(0, 2)[1];
      const [name, ...targs] = rest;
      if (!name || !/^[a-z][a-z0-9-]*$/.test(name)) throw new UsageError("usage: kcc tool <name> [args]   (a script name from .KCC/tools, without extension)");
      const r = runTool(workspace(toolDir), name, targs);
      if (r.stderr) console.error(r.stderr);
      return r.status;
    }
    case "mcp":
      if (rest.includes("--register")) {
        const i = rest.indexOf("--dir");
        registerMcp(workspace(i >= 0 ? rest[i + 1] : undefined));
        return 0;
      }
      return serveMcp(rest);
    default:
      throw new UsageError(`unknown command '${cmd}'. Run 'kcc help'.`);
  }
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (e: unknown) => {
    if (e instanceof UsageError) {
      console.error(`kcc: ${e.message}`);
      process.exit(2);
    }
    console.error(e);
    process.exit(1);
  },
);
