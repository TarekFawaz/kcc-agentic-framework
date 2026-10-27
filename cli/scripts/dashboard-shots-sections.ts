// Readable per-section screenshots of the dashboard overview. Usage: bun run scripts/dashboard-shots-sections.ts <dashboard/index.html> <outDir>
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
const sections: [string, string, number][] = [
  ["1-top", "", 1000],
  ["2-lifecycle-pipeline", "lifecycle pipeline", 1000],
  ["3-model-and-effort", "model and effort", 760],
  ["4-parallel-timeline", "parallel timeline", 1000],
  ["5-flowchart-shared-and-spec001", "lifecycle flowchart", 1100],
];
try {
  await page.gotoClean(url + "#/overview");
  await page.waitFor("document.querySelectorAll('#tabs .tab').length > 0", 20000);
  await page.sleep(2000);
  for (const [name, heading, h] of sections) {
    await page.setSize(1440, h);
    if (heading) {
      const ok = await page.eval<boolean>(`(function(){var hs=Array.prototype.slice.call(document.querySelectorAll('h1,h2,h3,summary'));var e=hs.find(function(x){return (x.textContent||'').trim().toLowerCase().indexOf(${JSON.stringify(heading)})===0;});if(!e)return false;e.scrollIntoView({block:'start'});window.scrollBy(0,-14);return true;})()`);
      if (!ok) console.log("heading not found:", heading);
    } else {
      await page.eval("window.scrollTo(0,0)");
    }
    await page.sleep(700);
    await page.screenshot(join(out, `r13-overview-${name}.png`));
    console.log("shot", name);
  }
} finally {
  page.close();
}
