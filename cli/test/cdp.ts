import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// A tiny Chrome DevTools Protocol driver for the dashboard tests: launches a headless Chrome on a private profile, opens one page and lets a test
// evaluate script in it, wait, resize and take screenshots. Bun's WebSocket is the only transport; nothing is installed.
export function findChromeBin(): string | undefined {
  const env = process.env.KCC_CHROME ?? process.env.CHROME;
  const list = [env, "C:/Program Files/Google/Chrome/Application/chrome.exe", "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe", "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe", "C:/Program Files/Microsoft/Edge/Application/msedge.exe", "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"];
  return list.find((p) => !!p && existsSync(p)) as string | undefined;
}

export interface Page {
  eval<T = unknown>(expr: string): Promise<T>;
  goto(url: string): Promise<void>;
  /** Navigates with this tab's session and local storage emptied before the page's own script runs (a page that was left saves its state on the way out). */
  gotoClean(url: string): Promise<void>;
  sleep(ms: number): Promise<void>;
  waitFor(expr: string, timeoutMs?: number): Promise<void>;
  setSize(w: number, h: number): Promise<void>;
  screenshot(file: string, opts?: { fullPage?: boolean }): Promise<void>;
  downloadsTo(dir: string): Promise<void>;
  close(): void;
}

export async function openPage(chrome: string, opts: { width?: number; height?: number; env?: Record<string, string> } = {}): Promise<Page> {
  const dir = mkdtempSync(join(tmpdir(), "kcc-cdp-"));
  const proc = spawn(chrome, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--remote-debugging-port=0", `--user-data-dir=${dir}`, `--window-size=${opts.width ?? 1400},${opts.height ?? 900}`, "about:blank"], { stdio: "ignore", env: { ...process.env, ...(opts.env ?? {}) } });
  const portFile = join(dir, "DevToolsActivePort");
  const t0 = Date.now();
  while (!existsSync(portFile)) {
    if (Date.now() - t0 > 20000) { proc.kill(); throw new Error("Chrome did not open a debugging port"); }
    await new Promise((r) => setTimeout(r, 100));
  }
  await new Promise((r) => setTimeout(r, 100));
  const port = Number(readFileSync(portFile, "utf8").split(/\r?\n/)[0]);
  let wsUrl = "";
  for (let i = 0; i < 50 && !wsUrl; i++) {
    try {
      const list = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()) as Array<{ type: string; webSocketDebuggerUrl: string }>;
      wsUrl = list.find((t) => t.type === "page")?.webSocketDebuggerUrl ?? "";
    } catch { /* not up yet */ }
    if (!wsUrl) await new Promise((r) => setTimeout(r, 100));
  }
  if (!wsUrl) { proc.kill(); throw new Error("no page target"); }
  const ws = new WebSocket(wsUrl);
  await new Promise<void>((res, rej) => { ws.onopen = () => res(); ws.onerror = () => rej(new Error("websocket failed")); });
  let id = 0;
  const pending = new Map<number, { res: (v: any) => void; rej: (e: Error) => void }>();
  ws.onmessage = (m) => {
    const msg = JSON.parse(String(m.data));
    if (msg.id && pending.has(msg.id)) {
      const p = pending.get(msg.id)!;
      pending.delete(msg.id);
      msg.error ? p.rej(new Error(msg.error.message)) : p.res(msg.result);
    }
  };
  const send = (method: string, params: Record<string, unknown> = {}): Promise<any> => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
  await send("Page.enable");
  await send("Runtime.enable");
  const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
  const page: Page = {
    async eval<T>(expr: string) {
      const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
      return r.result.value as T;
    },
    async goto(url: string) {
      await send("Page.navigate", { url });
      const t = Date.now();
      for (;;) {
        await sleep(100);
        try { if ((await page.eval<string>("document.readyState")) === "complete" && (url === "about:blank" || (await page.eval<string>("location.href")) !== "about:blank")) break; } catch { /* navigating */ }
        if (Date.now() - t > 30000) throw new Error("page did not load: " + url);
      }
      await sleep(150);
    },
    async gotoClean(url: string) {
      const r = await send("Page.addScriptToEvaluateOnNewDocument", { source: "try{sessionStorage.clear();localStorage.clear()}catch(e){}" });
      try { await page.goto(url); } finally { await send("Page.removeScriptToEvaluateOnNewDocument", { identifier: r.identifier }); }
    },
    sleep,
    async waitFor(expr: string, timeoutMs = 10000) {
      const t = Date.now();
      while (Date.now() - t < timeoutMs) { try { if (await page.eval<boolean>(`!!(${expr})`)) return; } catch { /* retry */ } await sleep(100); }
      throw new Error("timed out waiting for: " + expr);
    },
    async setSize(w: number, h: number) { await send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false }); },
    async screenshot(file: string, o = {}) {
      const params: Record<string, unknown> = { format: "png" };
      if (o.fullPage) {
        const m = await send("Page.getLayoutMetrics");
        const c = m.cssContentSize ?? m.contentSize;
        params.clip = { x: 0, y: 0, width: c.width, height: Math.min(c.height, 16000), scale: 1 };
        params.captureBeyondViewport = true;
      }
      const r = await send("Page.captureScreenshot", params);
      await Bun.write(file, Buffer.from(r.data, "base64"));
    },
    async downloadsTo(d: string) { await send("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: d }); },
    close() { try { ws.close(); } catch { /* */ } try { proc.kill(); } catch { /* */ } setTimeout(() => { try { rmSync(dir, { recursive: true, force: true }); } catch { /* locked */ } }, 1500); },
  };
  return page;
}
