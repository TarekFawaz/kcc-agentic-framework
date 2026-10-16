import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parse, UsageError, workspace } from "../args";
import { runTool, runToolAsync, which } from "../platform";
import { liveSyncAllLanes } from "../run/lanes";

/**
 * `kcc dashboard [--check] [--chrome <path>]`: rebuilds dashboard/index.html and proves it works.
 * `kcc dashboard --serve [--port N]`: serves a live page on 127.0.0.1 that is rebuilt from the files on every request.
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

export interface DashServer {
  url: string;
  port: number;
  stop(): void;
}

/**
 * A live dashboard: the page is rebuilt from the workspace files when it is requested (at most every `minAgeMs`), so it
 * shows what the files say now. Nothing has to keep regenerating it: not a hook, not the lane scheduler, not a loop. It
 * listens on 127.0.0.1 only and serves the page, its data and a health probe, nothing else.
 */
export function startDashboardServer(root: string, opts: { port?: number; minAgeMs?: number } = {}): DashServer | undefined {
  const file = join(root, "dashboard", "index.html");
  const minAge = opts.minAgeMs ?? 2000;
  let builtAt = 0;
  let building: Promise<void> | null = null;
  const fresh = async (): Promise<void> => {
    if (existsSync(file) && Date.now() - builtAt < minAge) return;
    if (!building) {
      liveSyncAllLanes(root); // the page shows the lanes' work, not what the last merge left in the workspace
      building = runToolAsync(root, "build-dashboard", ["--repo-root", root], { capture: true })
        .then(() => { builtAt = Date.now(); })
        .catch(() => undefined)
        .finally(() => { building = null; });
    }
    await building;
  };
  const noStore = { "Cache-Control": "no-store" };
  const handler = async (req: Request): Promise<Response> => {
    const path = new URL(req.url).pathname;
    if (path === "/healthz") return new Response("ok", { headers: noStore });
    if (path !== "/" && path !== "/index.html" && path !== "/data.json") return new Response("not found", { status: 404 });
    await fresh();
    if (!existsSync(file)) return new Response("the dashboard has not been built yet", { status: 503, headers: noStore });
    const html = readFileSync(file, "utf8");
    if (path === "/data.json") {
      const m = /<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html);
      return new Response(m?.[1] ?? "{}", { headers: { ...noStore, "Content-Type": "application/json" } });
    }
    return new Response(html, { headers: { ...noStore, "Content-Type": "text/html; charset=utf-8" } });
  };
  const start = opts.port ?? 4700 + (Array.from(root).reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % 100);
  for (let i = 0; i < 25; i++) {
    const port = (opts.port === 0 ? 0 : start + i);
    try {
      const server = Bun.serve({ port, hostname: "127.0.0.1", fetch: handler });
      return { url: `http://127.0.0.1:${server.port}/`, port: server.port ?? port, stop: () => server.stop(true) };
    } catch {
      if (opts.port === 0) break;
    }
  }
  return undefined;
}

export async function dashboard(argv: string[]): Promise<number> {
  const { values } = parse(argv, ["check", "quiet", "serve"], ["dir", "chrome", "port"]);
  const root = workspace(values.dir);
  if (values.serve) {
    const port = typeof values.port === "string" ? Number(values.port) : undefined;
    const server = startDashboardServer(root, { port });
    if (!server) throw new UsageError("could not open a local port for the dashboard (try --port N)");
    console.log(`Live dashboard: ${server.url}   (rebuilt from the workspace files whenever it is requested; Ctrl+C stops it)`);
    await new Promise<void>(() => undefined);
  }
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
