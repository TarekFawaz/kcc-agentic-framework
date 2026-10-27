// Full-page screenshots of every dashboard view. Usage: bun run scripts/dashboard-shots-full.ts <dashboard/index.html> <outDir>
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
const views: [string, string][] = [
  ["overview", "#/overview"],
  ["specs", "#/specs/SPEC-001"],
  ["roadmap", "#/roadmap"],
  ["activity", "#/activity"],
  ["agents", "#/agents"],
];
try {
  for (const [name, hash] of views) {
    await page.gotoClean(url + hash);
    await page.waitFor("document.querySelectorAll('#tabs .tab').length > 0", 20000);
    await page.sleep(1800);
    // size the viewport to the whole document so one screenshot shows the entire page
    const h = await page.eval<number>("Math.min(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight), 6000)");
    await page.setSize(1440, Math.max(h, 1000));
    await page.sleep(500);
    await page.screenshot(join(out, `r13-${name}.png`));
    await page.setSize(1440, 1000);
    console.log(name, "height", h);
  }
} finally {
  page.close();
}
