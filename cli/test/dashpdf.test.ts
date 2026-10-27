import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { payloadFiles } from "../src/payload";
import { findChromeBin, openPage, type Page } from "./cdp";
import { fileUrl, makeDashWorkspace, type DashFixture } from "./dashfixture";

// "Download PDF" of the timeline: a real .pdf written by hand in the page (no library, offline): header, catalog, pages, one JPEG image
// (/DCTDecode) per A3 landscape page, a cross-reference table with true offsets, trailer. The writer is checked on its own, then the browser export
// is run on a real timeline in headless Chrome and the bytes are parsed back (pages, xref, every stream length, the JPEGs themselves).
setDefaultTimeout(240000);
const chrome = findChromeBin();
const t = chrome ? test : test.skip;
const keep = process.env.KCC_TEST_KEEP ? join(tmpdir(), "kcc-dashpdf-out") : "";

const latin = (b: Uint8Array): string => Buffer.from(b).toString("latin1");

interface Parsed { pages: number; count: number; objects: number; images: Array<{ w: number; h: number; jpeg: Buffer }>; mediaBox: string }
/** Parses what pdfBytes writes and fails loudly on any structural error: xref offsets, stream lengths, trailer. */
function parsePdf(bytes: Uint8Array): Parsed {
  const s = latin(bytes);
  expect(s.startsWith("%PDF-1.")).toBe(true);
  expect(s.endsWith("%%EOF")).toBe(true);
  const sx = /startxref\n(\d+)\n%%EOF$/.exec(s);
  expect(sx).not.toBeNull();
  const xo = Number(sx![1]);
  expect(s.slice(xo, xo + 5)).toBe("xref\n");
  const head = /^xref\n0 (\d+)\n/.exec(s.slice(xo))!;
  const size = Number(head[1]);
  const entries = s.slice(xo + head[0].length).split("\n").slice(0, size);
  expect(entries.length).toBe(size);
  expect(entries[0]).toBe("0000000000 65535 f ");
  entries.forEach((e) => expect(e.length).toBe(19)); // 19 chars + the newline = the 20-byte entries the spec requires
  const trailer = /trailer\n<< \/Size (\d+) \/Root (\d+) 0 R \/Info (\d+) 0 R >>/.exec(s)!;
  expect(Number(trailer[1])).toBe(size);
  for (let i = 1; i < size; i++) {
    const off = Number(entries[i]!.slice(0, 10));
    expect(entries[i]!.endsWith(" 00000 n ")).toBe(true);
    expect(s.slice(off, off + `${i} 0 obj\n`.length)).toBe(`${i} 0 obj\n`); // every offset lands on its object
  }
  const pageObjs = (s.match(/\/Type \/Page(?![s\w])/g) ?? []).length;
  const count = Number(/\/Type \/Pages \/Kids \[[^\]]*\] \/Count (\d+)/.exec(s)![1]);
  const images: Parsed["images"] = [];
  const re = /\/Subtype \/Image \/Width (\d+) \/Height (\d+) \/ColorSpace \/DeviceRGB \/BitsPerComponent 8 \/Filter \/DCTDecode \/Length (\d+) >>\nstream\n/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s))) {
    const at = m.index + m[0].length, len = Number(m[3]);
    expect(s.slice(at + len, at + len + 10)).toBe("\nendstream"); // the declared /Length is the real one
    images.push({ w: Number(m[1]), h: Number(m[2]), jpeg: Buffer.from(bytes.slice(at, at + len)) });
  }
  return { pages: pageObjs, count, objects: size - 1, images, mediaBox: /\/MediaBox \[ ([\d. ]+) \]/.exec(s)![1]! };
}

describe("the PDF writer (pure, no browser)", () => {
  const tpl = payloadFiles().get("kernel/templates/dashboard.html")!.toString("utf8");
  const src = tpl.split("/*pdf-writer:start*/")[1]!.split("/*pdf-writer:end*/")[0]!;
  const pdfBytes = new Function(`${src}\nreturn pdfBytes;`)() as (p: Array<{ jpeg: Uint8Array; w: number; h: number }>, i?: Record<string, string>) => Uint8Array;
  const jpeg = (n: number): Uint8Array => { const a = new Uint8Array(n); for (let i = 0; i < n; i++) a[i] = (i * 31 + 7) & 255; a[0] = 0xff; a[1] = 0xd8; a[n - 2] = 0xff; a[n - 1] = 0xd9; return a; };
  test("one page, several pages, binary payload with newlines and parentheses", () => {
    for (const n of [1, 2, 7]) {
      const pages = Array.from({ length: n }, (_, i) => ({ jpeg: jpeg(300 + i * 97), w: 2800, h: 1980 }));
      const p = parsePdf(pdfBytes(pages, { title: "KCC (parallel) timeline \\ test", date: "20261016120000Z" }));
      expect(p.pages).toBe(n);
      expect(p.count).toBe(n);
      expect(p.objects).toBe(2 + 3 * n + 1);
      expect(p.images.length).toBe(n);
      expect(p.mediaBox).toBe("0 0 1190.55 841.89"); // A3 landscape in points
      p.images.forEach((im, i) => { expect(im.jpeg.equals(Buffer.from(pages[i]!.jpeg))).toBe(true); expect(im.w).toBe(2800); });
    }
  });
});

describe("Download PDF in a real browser", () => {
  let fx: DashFixture, big: DashFixture;
  let page: Page;
  const dl = join(tmpdir(), "kcc-dashpdf-dl-" + process.pid);
  const url = (f: DashFixture): string => fileUrl(f.file, `tz=UTC&theme=light&test=1&now=${encodeURIComponent(f.nowIso)}`);
  const exportPdf = async (): Promise<{ bytes: Buffer; name: string; pages: number; cols: number; rows: number; scaled: boolean; ppm: number }> => {
    const r = await page.eval<{ b64: string; name: string; pages: number; cols: number; rows: number; scaled: boolean; ppm: number }>(`window.__kccTest.tlExport().then(function(r){var s='',a=r.bytes,i,CH=0x8000;for(i=0;i<a.length;i+=CH)s+=String.fromCharCode.apply(null,a.subarray(i,i+CH));return {b64:btoa(s),name:r.name,pages:r.pages,cols:r.cols,rows:r.rows,scaled:r.scaled,ppm:r.ppm};})`);
    return { bytes: Buffer.from(r.b64, "base64"), name: r.name, pages: r.pages, cols: r.cols, rows: r.rows, scaled: r.scaled, ppm: r.ppm };
  };
  beforeAll(async () => {
    if (!chrome) return;
    fx = makeDashWorkspace({ specs: 40, spreadMin: 7, running: true });
    big = makeDashWorkspace({ specs: 60, spreadMin: 90, running: true }); // about 90 hours of timeline: wider than any page row
    mkdirSync(dl, { recursive: true });
    if (keep) mkdirSync(keep, { recursive: true });
    page = await openPage(chrome, { width: 1400, height: 900 });
    await page.setSize(1400, 900);
  });
  afterAll(() => {
    page?.close();
    for (const f of [fx, big]) if (f && !process.env.KCC_TEST_KEEP) rmSync(f.root, { recursive: true, force: true });
    rmSync(dl, { recursive: true, force: true });
  });

  t("exports the whole timeline as a valid PDF: %PDF- ... %%EOF, one page object per tile, valid xref, JPEG pages", async () => {
    await page.goto(url(fx));
    await page.waitFor("window.__kccTest && document.getElementById('tlscroll')");
    const r = await exportPdf();
    const p = parsePdf(r.bytes);
    expect(r.name).toMatch(/^kcc-timeline-\d{8}-\d{4}\.pdf$/);
    expect(p.pages).toBe(r.pages);
    expect(p.count).toBe(r.pages);
    expect(r.pages).toBe(r.cols * r.rows);
    expect(r.pages).toBeGreaterThan(1); // 40 specs, 160 runs: more than one page down
    expect(r.scaled).toBe(false);
    p.images.forEach((im) => { expect(im.w).toBe(2800); expect(im.h).toBe(1980); expect(im.jpeg[0]).toBe(0xff); expect(im.jpeg[1]).toBe(0xd8); expect(im.jpeg.at(-2)).toBe(0xff); expect(im.jpeg.at(-1)).toBe(0xd9); });
    if (keep) { writeFileSync(join(keep, r.name), r.bytes); p.images.slice(0, 2).forEach((im, i) => writeFileSync(join(keep, `page${i + 1}.jpg`), im.jpeg)); }
  });

  t("a long timeline is narrowed to at most four pages across and still exports (the largest tested)", async () => {
    await page.goto(url(big));
    await page.waitFor("window.__kccTest && document.getElementById('tlscroll')");
    const info = await page.eval<{ W: number; ppm: number }>("window.__kccTest.state().model");
    expect(info.W).toBeGreaterThan(20000); // the on-screen timeline is tens of thousands of pixels wide: that is what the scroller is for
    const t0 = Date.now();
    const r = await exportPdf();
    const p = parsePdf(r.bytes);
    expect(r.scaled).toBe(true);
    expect(r.cols).toBeLessThanOrEqual(4);
    expect(p.pages).toBe(r.cols * r.rows);
    expect(r.ppm).toBeLessThan(info.ppm);
    if (keep) { writeFileSync(join(keep, "long-" + r.name), r.bytes); p.images.slice(0, 1).forEach((im) => writeFileSync(join(keep, "long-page1.jpg"), im.jpeg)); console.log(`long timeline: ${info.W}px wide on screen, ${r.cols}x${r.rows}=${r.pages} pages, ${Math.round(r.bytes.length / 1024)} KB, ${Date.now() - t0} ms`); }
  });

  t("when the canvas export fails the reason is shown (not silent) and a print fallback is offered", async () => {
    await page.goto(url(fx));
    await page.waitFor("window.__kccTest && document.getElementById('tlscroll')");
    await page.eval(`window.__kccTest.failExport('SecurityError: the canvas has been tainted by cross-origin data');0`);
    await page.eval("window.__kccTest.tlDownload().then(function(){window.__done=1;});0");
    await page.waitFor("window.__done");
    const msg = await page.eval<{ hidden: boolean; text: string; print: boolean; bad: boolean; btn: boolean }>(`(function(){var m=document.getElementById('tlmsg');return {hidden:m.hidden,text:m.textContent,print:!!document.getElementById('tlprint'),bad:m.classList.contains('bad'),btn:!document.getElementById('tlpdf').disabled};})()`);
    expect(msg.hidden).toBe(false);
    expect(msg.text).toContain("The PDF could not be made");
    expect(msg.text).toContain("tainted");
    expect(msg.text).toContain("Nothing was saved");
    expect(msg.print).toBe(true);
    expect(msg.bad).toBe(true);
    expect(msg.btn).toBe(true); // the button works again
    // the print path only switches the page to print mode; check the stylesheet hides the rest of the page when it does
    const hidden = await page.eval<boolean>(`(function(){document.body.classList.add('printtl');var r=getComputedStyle(document.querySelector('.chrome')).display;document.body.classList.remove('printtl');return r;})()`);
    expect(hidden).not.toBe("none"); // screen media: print rules do not apply on screen
  });

  t("the button really downloads kcc-timeline-YYYYMMDD-HHMM.pdf", async () => {
    await page.goto(url(fx));
    await page.waitFor("window.__kccTest && document.getElementById('tlscroll')");
    await page.downloadsTo(dl);
    await page.eval("window.__kccTest.noClick=false;document.getElementById('tlpdf').click();0");
    await page.waitFor("document.getElementById('tlmsg') && /^Saved kcc-timeline-/.test(document.getElementById('tlmsg').textContent)", 120000);
    let file = "";
    for (let i = 0; i < 100 && !file; i++) {
      file = existsSync(dl) ? (readdirSync(dl).find((f) => /^kcc-timeline-\d{8}-\d{4}\.pdf$/.test(f)) ?? "") : "";
      if (!file) await page.sleep(200);
    }
    expect(file).not.toBe("");
    const p = parsePdf(readFileSync(join(dl, file)));
    expect(p.pages).toBeGreaterThan(1);
    const text = await page.eval<string>("document.getElementById('tlmsg').textContent");
    expect(text).toContain(`${p.pages} page`);
  });
});
