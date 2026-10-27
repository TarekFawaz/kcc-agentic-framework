import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { rmSync } from "node:fs";
import { payloadFiles } from "../src/payload";
import { findChromeBin, openPage, type Page } from "./cdp";
import { fileUrl, makeDashWorkspace, type DashFixture } from "./dashfixture";

// The owner's report: every refresh collapsed the open tables, the timeline showed UTC, and a long timeline was unreadable. These tests drive a real
// headless Chrome through the DevTools protocol (skipped when no browser is installed): open a details, scroll, zoom, refresh in place AND reload,
// and assert the person sees the same state; check the local-time labels; check the timeline is a scroller with a sticky axis and sticky labels.
setDefaultTimeout(240000);
const chrome = findChromeBin();
const t = chrome ? test : test.skip;
let fx: DashFixture;
let page: Page;
const Q = (extra = ""): string => `tz=UTC&theme=light&test=1&now=${encodeURIComponent(fx.nowIso)}${extra}`;

async function load(q = Q(), hash = "", f: DashFixture = fx, ready = "document.getElementById('tlscroll')"): Promise<void> {
  await page.gotoClean(fileUrl(f.file, q) + hash); // each test starts from a page nobody has touched
  await page.waitFor("window.__kccTest && " + ready);
}
async function reload(): Promise<void> {
  await page.eval("window.__old=1;window.__kccTest.saveUI();location.reload();0");
  await page.waitFor("!window.__old && document.readyState==='complete' && window.__kccTest");
  await page.sleep(300);
}
const openKeys = (): Promise<string[]> => page.eval(`Array.from(document.querySelectorAll('details')).filter(d=>d.open).map(d=>d.querySelector('summary').textContent.trim())`);

beforeAll(async () => {
  if (!chrome) return;
  fx = makeDashWorkspace({ specs: 40, spreadMin: 7, running: true });
  page = await openPage(chrome, { width: 1000, height: 760 });
  await page.setSize(1000, 760);
});
afterAll(() => {
  page?.close();
  if (fx && !process.env.KCC_TEST_KEEP) rmSync(fx.root, { recursive: true, force: true });
});

describe("a refresh keeps what the person sees", () => {
  t("every open <details> stays open across an in-place refresh, a view switch and a full reload", async () => {
    await load();
    const before = await page.eval<number>("document.querySelectorAll('details').length");
    expect(before).toBeGreaterThanOrEqual(3); // the runs table and one transitions table per flowchart
    await page.eval(`(function(){var d=document.querySelectorAll('details');d[0].open=true;d[2].open=true;})()`);
    await page.sleep(200);
    const opened = await openKeys();
    expect(opened.length).toBe(2);
    expect(await page.eval<number>("window.__kccTest.state().details && Object.keys(window.__kccTest.state().details).length")).toBe(2);
    // 1. the page re-renders in place (the live refresh path)
    await page.eval("window.__kccTest.softRefresh();0");
    expect(await openKeys()).toEqual(opened);
    // 2. the details a view creates later: leave the overview and come back, the view is rebuilt
    await page.eval("location.hash='#/roadmap';0");
    await page.sleep(200);
    await page.eval("location.hash='#/overview';0");
    await page.sleep(300);
    expect(await openKeys()).toEqual(opened);
    // 3. a full reload saves the state first
    await reload();
    expect(await openKeys()).toEqual(opened);
    // closing one is remembered too
    await page.eval(`(function(){var d=Array.from(document.querySelectorAll('details')).filter(d=>d.open)[0];d.open=false;})()`);
    await page.sleep(200);
    await page.eval("window.__kccTest.softRefresh();0");
    expect((await openKeys()).length).toBe(1);
  });

  t("the polling step: unchanged data re-renders nothing that moves; changed data reloads after saving", async () => {
    await load();
    await page.eval(`document.querySelectorAll('details')[0].open=true;0`);
    await page.sleep(200);
    const html = await page.eval<string>("document.documentElement.outerHTML");
    const raw = /<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html)![1]!;
    // the server rebuilt the page: only generatedAt differs
    const same = "<html><script id=\"kcc-data\" type=\"application/json\">" + raw.replace(/"generatedAt":"[^"]*"/, '"generatedAt":"2030-01-01T00:00:00Z"') + "</script></html>";
    expect(await page.eval<string>(`window.__kccTest.pollOnce(${JSON.stringify(same)})`)).toBe("same");
    expect((await openKeys()).length).toBe(1);
    // different data: the page reloads, and the open details survive it
    const changed = "<html><script id=\"kcc-data\" type=\"application/json\">" + raw.replace(/"project":"[^"]*"/, '"project":"other"') + "</script></html>";
    await page.eval(`window.__old=1;window.__kccTest.pollOnce(${JSON.stringify(changed)});0`);
    await page.waitFor("!window.__old && document.readyState==='complete' && window.__kccTest");
    await page.sleep(300);
    expect((await openKeys()).length).toBe(1);
  });

  t("page scroll, the timeline's own scroll and zoom, the window selector and the focused element survive", async () => {
    await load();
    await page.eval(`document.getElementById('tlzi').click();0`);
    await page.eval(`document.getElementById('tlzi').click();0`);
    const zoomed = await page.eval<number>("window.__kccTest.state().model.ppm");
    expect(zoomed).toBeGreaterThan(6.5);
    await page.eval(`(function(){var s=document.getElementById('tlscroll');s.scrollLeft=420;s.scrollTop=90;document.getElementById('tlcard').scrollIntoView();window.scrollBy(0,37);s.focus();})()`);
    await page.sleep(300);
    const snap = (): Promise<any> => page.eval(`(function(){var s=document.getElementById('tlscroll');return {y:Math.round(window.scrollY),l:Math.round(s.scrollLeft),t:Math.round(s.scrollTop),ppm:Math.round(window.__kccTest.state().model.ppm*100),focus:document.activeElement&&document.activeElement.id,hash:location.hash};})()`);
    const a = await snap();
    expect(a.l).toBeGreaterThan(300);
    expect(a.y).toBeGreaterThan(100);
    expect(a.focus).toBe("tlscroll");
    await page.eval("window.__kccTest.softRefresh();0");
    expect(await snap()).toEqual(a);
    await reload();
    expect(await snap()).toEqual(a);
    // the window selector is the other timeline control that used to be lost
    await page.eval(`(function(){var s=document.getElementById('tlrange');s.value='3600000';s.onchange();})()`);
    await reload();
    expect(await page.eval<string>("document.getElementById('tlrange').value")).toBe("3600000");
  });

  t("the selected tab and a filter in it survive a reload", async () => {
    await load(Q(), "#/activity", fx, "document.getElementById('ft')");
    await page.eval(`(function(){var i=document.getElementById('ft');i.focus();i.value='SPEC-003';i.oninput.call(i);i.setSelectionRange(2,5);})()`);
    await reload();
    expect(await page.eval<string>("location.hash")).toBe("#/activity");
    expect(await page.eval<string>("document.getElementById('ft').value")).toBe("SPEC-003");
    expect(await page.eval<string>("document.activeElement.id")).toBe("ft");
    expect(await page.eval<string>("document.querySelector('.tab.on').textContent")).toContain("Activity");
  });
});

describe("the page shows the viewer's own time, not UTC", () => {
  t("?tz= pins the zone: axis, legend note, tooltips, run table and event times follow it; the UTC value stays in a tooltip", async () => {
    await load(Q().replace("tz=UTC", "tz=Asia/Kolkata"));
    const note = await page.eval<string>("document.getElementById('tlzone').textContent");
    expect(note).toBe("times in Asia/Kolkata time, UTC+05:30");
    const corner = await page.eval<string>("document.querySelector('.tlcorner').textContent");
    expect(corner).toContain("UTC+05:30");
    // the first run starts at 08:00 UTC = 13:30 in India
    const cells = await page.eval<Array<[string, string]>>(`Array.from(document.querySelectorAll('#tlcard details tr td.mono[title^="UTC"]')).map(function(td){return [td.textContent,td.title];})`);
    expect(cells.length).toBeGreaterThan(20);
    const ist = new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Kolkata", hourCycle: "h23", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
    for (const [text, title] of cells.slice(0, 60)) {
      const parts = Object.fromEntries(ist.formatToParts(new Date(title.slice(4))).map((x) => [x.type, x.value]));
      expect(text).toBe(`${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`); // local, and the UTC instant is in the title
    }
    expect(cells.some(([text]) => text === "10-16 13:30")).toBe(true); // the first run starts at 08:00 UTC
    const tip = await page.eval<string>("document.querySelector('.tlscroll .bar title').textContent");
    expect(tip).toContain("local (UTC 10-16 08:00 to");
    expect(tip).toContain("10-16 13:30 to");
    const axis = await page.eval<string>("Array.from(document.querySelectorAll('.tlhead .axl')).map(function(e){return e.textContent;}).join(' ')");
    expect(axis).toMatch(/14:00 15:00 16:00/); // ticks fall on local clock marks (UTC+05:30 is half an hour off the UTC ones)
    expect(axis).not.toMatch(/\b08:00\b/);
    await page.goto("about:blank");
    await page.goto(fileUrl(fx.file, Q()));
    await page.waitFor("window.__kccTest && document.getElementById('tlscroll')");
    expect(await page.eval<string>("document.getElementById('tlzone').textContent")).toBe("times in UTC");
    expect(await page.eval<string>("document.getElementById('foot').textContent")).toContain("UTC");
  });

  t("without ?tz= the page uses the machine zone and says which one, once, in the legend", async () => {
    await load(`theme=light&test=1&now=${encodeURIComponent(fx.nowIso)}`);
    const note = await page.eval<string>("document.getElementById('tlzone').textContent");
    const sys = await page.eval<string>("Intl.DateTimeFormat().resolvedOptions().timeZone");
    expect(note.startsWith("times in local time, UTC")).toBe(true);
    expect(note).toContain(`(${sys})`);
    expect(await page.eval<number>("document.querySelectorAll('#tlzone').length")).toBe(1);
  });
});

describe("the timeline is a scroller", () => {
  t("max 70vh, scrolls both ways, the axis and the row labels stay put, zoom and fit and now work, keys work", async () => {
    await load();
    const g = (js: string): Promise<any> => page.eval(js);
    const m = await g(`(function(){var s=document.getElementById('tlscroll'),r=s.getBoundingClientRect();return {h:r.height,ih:innerHeight,sw:s.scrollWidth,cw:s.clientWidth,sh:s.scrollHeight,ch:s.clientHeight,tab:s.tabIndex,ov:getComputedStyle(s).overflow};})()`);
    expect(m.h).toBeLessThanOrEqual(m.ih * 0.7 + 2);
    expect(m.sw).toBeGreaterThan(m.cw);
    expect(m.sh).toBeGreaterThan(m.ch);
    expect(m.tab).toBe(0);
    expect(m.ov).toBe("auto");
    await g(`document.getElementById('tlcard').scrollIntoView();0`);
    await g(`(function(){var s=document.getElementById('tlscroll');s.scrollLeft=500;s.scrollTop=300;})()`);
    await page.sleep(250);
    const st = await g(`(function(){var s=document.getElementById('tlscroll').getBoundingClientRect(),h=document.querySelector('.tlhead').getBoundingClientRect(),c=document.querySelector('.tlcorner').getBoundingClientRect(),l=document.querySelector('.tllab').getBoundingClientRect(),stg=document.getElementById('tlstage');
      return {headTop:Math.round(h.top-s.top),cornerLeft:Math.round(c.left-s.left),labLeft:Math.round(l.left-s.left),stageShown:!stg.hidden,stageText:stg.textContent};})()`);
    expect(Math.abs(st.headTop)).toBeLessThanOrEqual(2); // sticky axis
    expect(Math.abs(st.cornerLeft)).toBeLessThanOrEqual(2);
    expect(Math.abs(st.labLeft)).toBeLessThanOrEqual(2); // sticky labels
    expect(st.stageShown).toBe(true); // the stage header that scrolled away stays readable
    expect(st.stageText).toMatch(/^\d+ [A-Z]+\s+-\s+\d+ runs?/);
    // zoom out/in change px per minute and keep the centre moment
    const p0 = await g("window.__kccTest.state().model.ppm");
    await g(`document.getElementById('tlzi').click();0`);
    const p1 = await g("window.__kccTest.state().model.ppm");
    expect(p1 / p0).toBeCloseTo(1.5, 1);
    await g(`document.getElementById('tlzo').click();document.getElementById('tlzo').click();0`);
    expect(await g("window.__kccTest.state().model.ppm")).toBeCloseTo(p0 / 1.5, 1);
    // fit: the whole run in the width
    await g(`document.getElementById('tlfit').click();0`);
    const fit = await g(`(function(){var s=document.getElementById('tlscroll');return {sw:s.scrollWidth,cw:s.clientWidth,z:document.getElementById('tlzoom').textContent};})()`);
    expect(fit.sw).toBeLessThanOrEqual(fit.cw + 2);
    expect(fit.z).toContain("(fit)");
    await g(`document.getElementById('tlreset').click();0`);
    expect(await g("window.__kccTest.state().model.ppm")).toBeGreaterThanOrEqual(6);
    // scroll to now moves right
    await g(`document.getElementById('tlscroll').scrollLeft=0;document.getElementById('tlnowbtn').click();0`);
    expect(await g("document.getElementById('tlscroll').scrollLeft")).toBeGreaterThan(100);
    // keyboard: the scroller takes focus, "+" zooms, Home goes to the start
    await g(`(function(){var s=document.getElementById('tlscroll');s.focus();s.dispatchEvent(new KeyboardEvent('keydown',{key:'+',bubbles:true}));})()`);
    expect(await g("window.__kccTest.state().model.ppm")).toBeGreaterThan(p0 * 1.4);
    await g(`document.getElementById('tlscroll').dispatchEvent(new KeyboardEvent('keydown',{key:'Home',bubbles:true}));0`);
    expect(await g("document.getElementById('tlscroll').scrollLeft")).toBe(0);
    // the fallback table is still there
    expect(await g("document.querySelectorAll('#tlcard details').length")).toBe(1);
  });

  t("the readable default is at least 6 px per minute; a short run fills the width", async () => {
    await load();
    expect(await page.eval<number>("window.__kccTest.state().model.ppm")).toBeGreaterThanOrEqual(6);
    const small = makeDashWorkspace({ specs: 1, running: false });
    try {
      await load(`tz=UTC&test=1&now=${encodeURIComponent(small.nowIso)}`, "", small);
      const r = await page.eval<{ ppm: number; fit: number; sw: number; cw: number }>(`(function(){var m=window.__kccTest.state().model,s=document.getElementById('tlscroll');return {ppm:m.ppm,fit:m.fitPPM,sw:s.scrollWidth,cw:s.clientWidth};})()`);
      expect(r.ppm).toBeCloseTo(Math.max(6, r.fit), 3);
      expect(r.sw).toBeLessThanOrEqual(r.cw + 2);
    } finally {
      rmSync(small.root, { recursive: true, force: true });
    }
  });
});

describe("local-time helpers (the template's own functions)", () => {
  const tpl = payloadFiles().get("kernel/templates/dashboard.html")!.toString("utf8");
  const block = tpl.split("/*parallel-view:start*/")[1]!.split("/*parallel-view:end*/")[0]!;
  // tz helpers only: they sit at the top of the block, before the run model
  const tzPart = "/* ---- local time" + block.split("/* ---- local time")[1]!.split("/* ---- the swimlane timeline (Gantt) ---- */")[0]!;
  const fns = new Function(`${tzPart}\nreturn {TZ,tzParts,tzOffMin,offLabel,tickLabel,dayKey,clockHMS,zoneNote,spanTip,utcLabel};`)();
  const ts = Date.parse("2026-10-16T23:45:00Z");
  test("UTC, a fixed zone, a half-hour zone and a daylight-saving zone", () => {
    fns.TZ.name = "UTC";
    expect(fns.tickLabel(ts, true)).toBe("10-16 23:45");
    expect(fns.zoneNote(ts)).toBe("times in UTC");
    fns.TZ.name = "Asia/Kolkata";
    expect(fns.tickLabel(ts, true)).toBe("10-17 05:15");
    expect(fns.dayKey(ts)).toBe("2026-10-17");
    expect(fns.zoneNote(ts)).toBe("times in Asia/Kolkata time, UTC+05:30");
    fns.TZ.name = "America/New_York";
    expect(fns.offLabel(fns.tzOffMin(ts))).toBe("UTC-04:00");
    expect(fns.offLabel(fns.tzOffMin(Date.parse("2026-12-16T12:00:00Z")))).toBe("UTC-05:00");
    expect(fns.zoneNote(ts, Date.parse("2026-12-16T12:00:00Z"))).toContain("the clocks change in this window");
    fns.TZ.name = "";
  });
  test("a tooltip span names the zone and carries the UTC value", () => {
    fns.TZ.name = "Asia/Kolkata";
    expect(fns.spanTip(ts, ts + 3600000, false)).toBe("10-17 05:15 to 10-17 06:15 local (UTC 10-16 23:45 to 10-17 00:45)");
    fns.TZ.name = "UTC";
    expect(fns.spanTip(ts, ts, true)).toBe("10-16 23:45 to now UTC");
    fns.TZ.name = "";
  });
});
