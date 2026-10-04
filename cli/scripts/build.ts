// Builds self-contained kcc binaries with `bun build --compile`.
//   bun run scripts/build.ts          -> dist/kcc[.exe] for this machine
//   bun run scripts/build.ts --all    -> every release target
import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const cliDir = join(import.meta.dir, "..");
const dist = join(cliDir, "dist");
mkdirSync(dist, { recursive: true });

const TARGETS: Record<string, string> = {
  "bun-windows-x64": "kcc-windows-x64.exe",
  "bun-darwin-arm64": "kcc-darwin-arm64",
  "bun-darwin-x64": "kcc-darwin-x64",
  "bun-linux-x64": "kcc-linux-x64",
  "bun-linux-arm64": "kcc-linux-arm64",
};

function run(args: string[]): void {
  const r = spawnSync("bun", args, { cwd: cliDir, stdio: "inherit" });
  if (r.status !== 0) process.exit(r.status ?? 1);
}

run(["run", "scripts/pack.ts"]);

if (process.argv.includes("--all")) {
  for (const [target, name] of Object.entries(TARGETS)) {
    run(["build", "src/main.ts", "--compile", "--minify", `--target=${target}`, "--outfile", join(dist, name)]);
  }
} else {
  const name = process.platform === "win32" ? "kcc.exe" : "kcc";
  run(["build", "src/main.ts", "--compile", "--minify", "--outfile", join(dist, name)]);
}
