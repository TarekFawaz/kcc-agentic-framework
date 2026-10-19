// Helper (not a test): screenshots of a built dashboard for the docs. Usage: bun run scripts/dashboard-shots.ts <dashboard/index.html> <outDir>
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { findChromeBin, openPage } from "../test/cdp";

const html = resolve(process.argv[2]!);
const out = resolve(process.argv[3]!);
mkdirSync(out, { recursive: true });
const chrome = findChromeBin();
if (!chrome) throw new Error("no Chrome found");
const url = "file:///" + html.replace(/\\/g, "/");
const page = await openPage(chrome, { width: 1440, height: 1000 });
try {
  await page.gotoClean(url + "#/overview");
  await page.waitFor("document.querySelectorAll('#tabs .tab').length > 0", 20000);
  await page.sleep(1500);
  await page.screenshot(join(out, "dashboard-overview.png"));
  // the parallel-agent timeline sits further down the overview
  const found = await page.eval<boolean>(`(function(){var hs=Array.prototype.slice.call(document.querySelectorAll('h2,h3,summary,.card h2,.card h3'));var h=hs.find(function(e){return /timeline|swimlane|agent runs/i.test(e.textContent||'');});if(!h)return false;h.scrollIntoView({block:'start'});window.scrollBy(0,-12);return true;})()`);
  await page.sleep(600);
  await page.screenshot(join(out, "dashboard-timeline.png"));
  console.log("timeline heading found:", found);
  await page.goto(url + "#/specs/SPEC-001");
  await page.sleep(1500);
  await page.eval("window.scrollTo(0,0)");
  await page.screenshot(join(out, "dashboard-spec.png"));
  await page.goto(url + "#/agents");
  await page.sleep(1200);
  await page.eval("window.scrollTo(0,0)");
  await page.screenshot(join(out, "dashboard-agents.png"));
  console.log("ok", out);
} finally {
  page.close();
}
