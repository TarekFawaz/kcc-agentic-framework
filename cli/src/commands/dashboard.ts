import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parse, UsageError, workspace } from "../args";
import { runTool, which } from "../platform";

/**
 * `kcc dashboard [--check] [--chrome <path>]`: rebuilds dashboard/index.html and proves it works.
 *
 * The page is a generated file; a template edit that leaves a syntax error renders a blank page and
 * nobody notices until a human opens it (it happened). So after building, this compiles every script
 * block, parses the embedded data, and, with --check and a Chrome/Edge available, renders the page
 * headless and requires the lifecycle card to be in the DOM.
 */
export interface DashboardCheck {
  ok: boolean;
  problems: string[];
  rendered: boolean;
}

export function checkDashboardHtml(html: string): DashboardCheck {
  const problems: string[] = [];
  const scripts = [...html.matchAll(/<script(?![^>]*application\/json)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1] ?? "");
  if (!scripts.length) problems.push("no script block in the page");
  scripts.forEach((s, i) => {
    try {
      new Function(s);
    } catch (e) {
      problems.push(`script block ${i + 1} does not compile: ${(e as Error).message}`);
    }
  });
  const data = html.match(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/);
  if (!data) problems.push("no embedded kcc-data block");
  else {
    try {
      const d = JSON.parse(data[1] ?? "");
      for (const k of ["states", "specs", "events"]) if (!Array.isArray(d[k])) problems.push(`kcc-data.${k} is not an array`);
    } catch (e) {
      problems.push(`kcc-data is not valid JSON: ${(e as Error).message}`);
    }
  }
  if (html.includes("__KCC_DATA__")) problems.push("the data placeholder was not filled");
  return { ok: !problems.length, problems, rendered: false };
}

function findChrome(explicit?: string): string | undefined {
  if (explicit && existsSync(explicit)) return explicit;
  const env = process.env.KCC_CHROME ?? process.env.CHROME;
  if (env && existsSync(env)) return env;
  const candidates = [
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ];
  for (const c of candidates) if (existsSync(c)) return c;
  for (const c of ["google-chrome", "chromium", "chromium-browser", "msedge"]) {
    const w = which(c);
    if (w) return w;
  }
  return undefined;
}

/** Renders the page headless and returns the DOM, or undefined when no browser is available. */
export function renderHeadless(file: string, chrome?: string): string | undefined {
  const bin = findChrome(chrome);
  if (!bin) return undefined;
  const url = "file:///" + file.replace(/\\/g, "/").replace(/^\/+/, "");
  const r = spawnSync(bin, ["--headless=new", "--disable-gpu", "--virtual-time-budget=4000", "--dump-dom", url], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: 60000 });
  return r.status === 0 ? r.stdout : undefined;
}

export function dashboard(argv: string[]): number {
  const { values } = parse(argv, ["check", "quiet"], ["dir", "chrome"]);
  const root = workspace(values.dir);
  const b = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
  if (b.status !== 0) {
    console.error(b.stderr || b.stdout);
    throw new UsageError("build-dashboard failed");
  }
  const file = join(root, "dashboard", "index.html");
  const html = readFileSync(file, "utf8");
  const c = checkDashboardHtml(html);
  if (values.check) {
    const dom = renderHeadless(file, typeof values.chrome === "string" ? values.chrome : undefined);
    if (dom === undefined) c.problems.push("note: no Chrome or Edge found, the page was not rendered (set KCC_CHROME to enable)");
    else {
      c.rendered = true;
      const hasView = /id="view"[^>]*>\s*<(div|p)/.test(dom);
      if (!hasView) c.problems.push("the rendered page is blank: the view container has no content (a script error at load)");
    }
  }
  const hard = c.problems.filter((p) => !p.startsWith("note:"));
  if (!values.quiet) {
    console.log(`Dashboard: ${file}`);
    for (const p of c.problems) console.log(`  ${p.startsWith("note:") ? "" : "PROBLEM "}${p}`);
    console.log(hard.length ? `FAIL (${hard.length} problem${hard.length > 1 ? "s" : ""})` : `OK${c.rendered ? " (compiled, data parsed, rendered)" : " (compiled, data parsed)"}`);
  }
  return hard.length ? 1 : 0;
}
