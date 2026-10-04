import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { Deployment, ProjectType, Stack } from "./model";

export interface Detected {
  name?: string;
  project_type?: ProjectType;
  stacks?: Stack[];
  has_ui?: boolean;
  deployment?: Deployment;
  existing_codebase?: boolean;
}

const SKIP_DIRS = new Set([".git", ".KCC", ".claude", ".codex", ".opencode", ".agents", "node_modules", "bin", "obj", "dist", "build", "target", ".venv", "venv", "Traces", "coordination", "memory", "specs", "ideation", "architecture", "solution", "migrations", "ollama", "dashboard"]);

function findMarkers(root: string, depth: number, out: string[]): void {
  let names: string[];
  try {
    names = readdirSync(root);
  } catch {
    return;
  }
  for (const name of names) {
    const full = join(root, name);
    let dir = false;
    try {
      dir = statSync(full).isDirectory();
    } catch {
      continue;
    }
    if (dir) {
      if (depth > 0 && !SKIP_DIRS.has(name) && !name.startsWith(".")) findMarkers(full, depth - 1, out);
    } else out.push(full);
  }
}

function add<T>(list: T[], v: T): void {
  if (!list.includes(v)) list.push(v);
}

/** Reads build files near the workspace root to pre-fill the questions. */
export function detectFromRepo(root: string): Detected {
  const files: string[] = [];
  findMarkers(root, 3, files);
  const stacks: Stack[] = [];
  let ui = false;
  let deployment: Deployment | undefined;
  for (const f of files) {
    const name = basename(f);
    if (name === "package.json") {
      add(stacks, "nodejs");
      try {
        const pkg = JSON.parse(readFileSync(f, "utf8")) as { dependencies?: Record<string, string>; devDependencies?: Record<string, string> };
        const deps = { ...pkg.dependencies, ...pkg.devDependencies };
        if (deps["react"]) { add(stacks, "react"); ui = true; }
        if (deps["@angular/core"]) { add(stacks, "angular"); ui = true; }
        if (deps["@nestjs/core"]) add(stacks, "nestjs");
        if (deps["react"] && deps["express"] && (deps["mongoose"] || deps["mongodb"])) add(stacks, "mern");
        if (deps["vue"] || deps["svelte"] || deps["next"]) ui = true;
      } catch {
        // an unreadable package.json still counts as a Node project
      }
    } else if (name === "pyproject.toml" || name === "requirements.txt" || name === "setup.py") add(stacks, "python");
    else if (name.endsWith(".csproj") || name.endsWith(".sln") || name.endsWith(".fsproj")) add(stacks, "dotnet");
    else if (name === "go.mod") add(stacks, "go");
    else if (name === "Cargo.toml") add(stacks, "rust");
    else if (name === "pom.xml" || name === "build.gradle" || name === "build.gradle.kts") add(stacks, "java");
    else if (name === "composer.json") add(stacks, "php");
    else if (name === "CMakeLists.txt") add(stacks, "cpp");
    else if (name === "Chart.yaml" || name === "kustomization.yaml") deployment = "kubernetes";
    else if ((name.endsWith(".tf") || name.endsWith(".bicep")) && !deployment) deployment = "cloud";
    else if (name.endsWith(".razor") || name === "index.html") ui = true;
  }
  const out: Detected = { name: basename(root) };
  if (stacks.length) {
    out.stacks = stacks;
    out.existing_codebase = true;
    out.has_ui = ui;
  }
  if (deployment) out.deployment = deployment;
  return out;
}

const KEYWORDS: [RegExp, Stack][] = [
  [/\bpython\b|\bdjango\b|\bfastapi\b|\bflask\b/i, "python"],
  [/\bnode(\.js|js)?\b|\bexpress\b|\btypescript\b/i, "nodejs"],
  [/\bnest(\.js|js)\b/i, "nestjs"],
  [/\bmern\b/i, "mern"],
  [/\breact\b|\bnext\.js\b/i, "react"],
  [/\bangular\b/i, "angular"],
  [/\.net\b|\bc#|\basp\.net\b|\bcsharp\b|\bblazor\b/i, "dotnet"],
  [/\bgolang\b|\bgo (service|module|backend)\b|\bgo\.mod\b/i, "go"],
  [/\brust\b|\bcargo\b/i, "rust"],
  [/\bjava\b|\bspring\b|\bkotlin\b/i, "java"],
  [/\bc\+\+|\bcmake\b/i, "cpp"],
  [/\bphp\b|\blaravel\b|\bsymfony\b/i, "php"],
];

/** Keyword scan of free text: a Markdown brief or the `/solution-onboard` baseline. */
export function detectFromText(text: string): Detected {
  const stacks: Stack[] = [];
  for (const [re, stack] of KEYWORDS) if (re.test(text)) add(stacks, stack);
  const out: Detected = {};
  if (stacks.length) out.stacks = stacks;
  if (/\b(web app|web application|dashboard|frontend|front-end|user interface|\bUI\b|SPA|mobile app)\b/i.test(text)) out.has_ui = true;
  if (/\b(no (ui|user interface|frontend)|headless|command[- ]line tool|CLI tool)\b/i.test(text)) out.has_ui = false;
  if (/\bkubernetes\b|\bk8s\b|\bhelm\b/i.test(text)) out.deployment = "kubernetes";
  else if (/\baws\b|\bazure\b|\bgcp\b|\bgoogle cloud\b|\bcloud\b/i.test(text)) out.deployment = "cloud";
  else if (/\bon[- ]prem(ise|ises)?\b|\bbare[- ]metal\b/i.test(text)) out.deployment = "onprem";
  if (/\bembedded\b|\bfirmware\b|\bmicrocontroller\b/i.test(text)) out.project_type = "embedded";
  else if (/\bcommand[- ]line tool\b|\bCLI tool\b/i.test(text)) out.project_type = "cli-tool";
  else if (/\blibrary\b|\bSDK\b|\bpackage\b/i.test(text) && out.has_ui !== true) out.project_type = "library";
  else if (/\bREST\b|\bAPI service\b|\bmicroservice/i.test(text) && out.has_ui !== true) out.project_type = "api-service";
  else if (out.has_ui) out.project_type = "web-app";
  return out;
}

/** The read-only baseline written by `/solution-onboard`. */
export function detectFromBaseline(root: string): Detected | undefined {
  const dir = join(root, "solution");
  const parts: string[] = [];
  for (const f of ["TechStack.md", "ArchitectureSnapshot.md", "RuntimeAndOperations.md", "solution.md"]) {
    const p = join(dir, f);
    if (existsSync(p)) parts.push(readFileSync(p, "utf8"));
  }
  if (!parts.length) return undefined;
  const out = detectFromText(parts.join("\n"));
  out.existing_codebase = true;
  return out;
}
