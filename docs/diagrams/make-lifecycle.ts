// Builds the README hero animation.
//   bun run docs/diagrams/make-lifecycle.ts            writes kcc-lifecycle.drawio only
//   bun run docs/diagrams/make-lifecycle.ts --gif      also exports every page with the draw.io
//                                                      desktop app and joins them into kcc-lifecycle.gif
// Needs for --gif: draw.io desktop (set DRAWIO to its executable if it is not in the default
// location) and ffmpeg on PATH.
//
// The .drawio file has one page per animation step. Every page holds the same shapes; only the
// colours change (waiting / active / done), so the pages can be edited or re-exported by hand too.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const here = import.meta.dir;
const W = 1600;
const H = 800;

type State = "wait" | "active" | "done";
type Kind = "setup" | "meta" | "stage" | "gate" | "check" | "loop";

const COLORS: Record<Kind, Record<State, { fill: string; stroke: string; font: string }>> = {
  setup: { wait: c("#F3F4F6", "#D1D5DB", "#9CA3AF"), active: c("#2563EB", "#1E3A8A", "#FFFFFF"), done: c("#DBEAFE", "#2563EB", "#1E3A8A") },
  meta: { wait: c("#F3F4F6", "#D1D5DB", "#9CA3AF"), active: c("#6366F1", "#312E81", "#FFFFFF"), done: c("#E0E7FF", "#6366F1", "#312E81") },
  stage: { wait: c("#F3F4F6", "#D1D5DB", "#9CA3AF"), active: c("#059669", "#064E3B", "#FFFFFF"), done: c("#D1FAE5", "#059669", "#064E3B") },
  gate: { wait: c("#F3F4F6", "#D1D5DB", "#9CA3AF"), active: c("#F59E0B", "#92400E", "#FFFFFF"), done: c("#FEF3C7", "#D97706", "#92400E") },
  check: { wait: c("#F3F4F6", "#D1D5DB", "#9CA3AF"), active: c("#0F766E", "#134E4A", "#FFFFFF"), done: c("#CCFBF1", "#0F766E", "#134E4A") },
  loop: { wait: c("#F3F4F6", "#D1D5DB", "#9CA3AF"), active: c("#DC2626", "#7F1D1D", "#FFFFFF"), done: c("#FEE2E2", "#DC2626", "#7F1D1D") },
};
function c(fill: string, stroke: string, font: string) {
  return { fill, stroke, font };
}

interface Node {
  id: string;
  kind: Kind;
  title: string;
  sub: string;
  x: number;
  y: number;
  w: number;
  h: number;
  diamond?: boolean;
}

// ---- layout -------------------------------------------------------------------------------
const nodes: Node[] = [
  // 1. set up once
  { id: "install", kind: "setup", title: "Install kcc", sub: "winget · brew · script", x: 60, y: 110, w: 270, h: 70 },
  { id: "init", kind: "setup", title: "kcc init", sub: "framework into the project", x: 390, y: 110, w: 270, h: 70 },
  { id: "tailor", kind: "setup", title: "kcc tailor", sub: "only the agents, skills and dialects you need", x: 720, y: 110, w: 330, h: 70 },
  { id: "adapters", kind: "setup", title: "Harness adapters", sub: "Claude Code · Codex · OpenCode · Ollama", x: 1110, y: 110, w: 430, h: 70 },
  // meta-agents
  { id: "butler", kind: "meta", title: "Butler", sub: "memory: brief before, remember after", x: 110, y: 250, w: 360, h: 60 },
  { id: "backchannel", kind: "meta", title: "Backchannel", sub: "append-only coordination log", x: 620, y: 250, w: 360, h: 60 },
  { id: "tokenguard", kind: "meta", title: "Token Guard", sub: "cost forecast + budget gate", x: 1130, y: 250, w: 360, h: 60 },
];

const STAGES: [string, Kind, string, string][] = [
  ["interrogate", "stage", "interrogate", "idea + specialists"],
  ["spec", "stage", "spec", "spec-writer"],
  ["gate1", "gate", "budget", "human approves"],
  ["plan", "stage", "plan", "planner"],
  ["gate2", "gate", "budget", "refined estimate"],
  ["implement", "stage", "implement", "implementer"],
  ["test", "stage", "test", "verifier"],
  ["review", "stage", "review", "PASS / FAIL per AC"],
  ["merge", "stage", "merge", "pull-request draft"],
  ["deploy", "stage", "deploy", "pipeline + IaC"],
];
const SW = 120;
const GAP = 31;
STAGES.forEach(([id, kind, title, sub], i) => {
  const gate = kind === "gate";
  nodes.push({ id, kind, title, sub, x: 60 + i * (SW + GAP), y: gate ? 395 : 405, w: SW, h: gate ? 100 : 80, diamond: gate });
});

nodes.push(
  { id: "checks", kind: "check", title: "Exit checks are scripts, not prose", sub: "conformance · traceability · wave scope · implementation lock · quality gate (build, tests, coverage, secrets, dependencies, SAST)", x: 60, y: 540, w: 1480, h: 60 },
  { id: "limit", kind: "loop", title: "kcc run: auto-continue on any harness", sub: "usage limit → restore point → wait for the reset → resume", x: 60, y: 640, w: 710, h: 70 },
  { id: "inspector", kind: "meta", title: "Learning loop", sub: "traces · costs · confidence → Inspector → reusable capabilities", x: 830, y: 640, w: 710, h: 70 },
);

const edges: [string, string][] = [
  ["install", "init"], ["init", "tailor"], ["tailor", "adapters"],
  ...STAGES.slice(1).map(([id], i) => [STAGES[i]![0], id] as [string, string]),
];

// ---- animation steps: which node becomes active on each page --------------------------------
const ORDER: string[][] = [
  [],
  ["install"], ["init"], ["tailor"], ["adapters"],
  ["butler", "backchannel", "tokenguard"],
  ["interrogate"], ["spec"], ["gate1"], ["plan"], ["gate2"],
  ["implement", "checks"], ["test"], ["review"], ["merge"], ["deploy"],
  ["limit"], ["inspector"],
  [], // final: everything done
];
const HOLD = ORDER.map((_, i) => (i === 0 ? 1.2 : i === ORDER.length - 1 ? 3.5 : 0.75));

// ---- drawio xml ---------------------------------------------------------------------------
const esc = (s: string): string => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function text(id: string, value: string, x: number, y: number, w: number, h: number, style: string): string {
  return `<mxCell id="${id}" parent="1" style="text;html=1;strokeColor=none;fillColor=none;whiteSpace=wrap;${style}" value="${esc(value)}" vertex="1"><mxGeometry x="${x}" y="${y}" width="${w}" height="${h}" as="geometry" /></mxCell>`;
}

function page(index: number): string {
  const state = new Map<string, State>();
  const last = index === ORDER.length - 1;
  for (const n of nodes) state.set(n.id, last ? "done" : "wait");
  for (let i = 0; i <= index; i++) for (const id of ORDER[i] ?? []) state.set(id, i === index && !last ? "active" : "done");

  const cells: string[] = [];
  cells.push(`<mxCell id="bg" parent="1" style="rounded=0;whiteSpace=wrap;html=1;fillColor=#FFFFFF;strokeColor=none;" value="" vertex="1"><mxGeometry x="0" y="0" width="${W}" height="${H}" as="geometry" /></mxCell>`);
  cells.push(text("title", "<b>KCC</b> &nbsp;from a raw idea to shipped, governed work, on any AI coding harness", 60, 18, 1480, 40, "align=center;verticalAlign=middle;fontSize=24;fontColor=#111827;"));
  cells.push(text("l1", "<b>1 &nbsp;Set up once</b> with the kcc command line", 60, 78, 700, 24, "align=left;verticalAlign=middle;fontSize=14;fontColor=#1E3A8A;"));
  cells.push(`<mxCell id="metabg" parent="1" style="rounded=1;arcSize=12;whiteSpace=wrap;html=1;fillColor=#F5F7FF;strokeColor=#A5B4FC;strokeWidth=2;dashed=1;" value="" vertex="1"><mxGeometry x="60" y="212" width="1480" height="116" as="geometry" /></mxCell>`);
  cells.push(text("l2", "<b>Meta-agents</b> wrap every turn at minimum token cost", 80, 218, 700, 24, "align=left;verticalAlign=middle;fontSize=13;fontColor=#4338CA;"));
  cells.push(text("l3", "<b>2 &nbsp;Lifecycle</b> &nbsp;run it with <b>auto &lt;idea&gt;</b> in your harness or <b>kcc run</b> in a terminal", 60, 358, 1000, 24, "align=left;verticalAlign=middle;fontSize=14;fontColor=#064E3B;"));
  cells.push(text("foot", "Humans approve budget, confidence and scope. KCC never pushes or deploys on its own.", 60, 735, 1480, 30, "align=center;verticalAlign=middle;fontSize=15;fontStyle=2;fontColor=#374151;"));

  for (const n of nodes) {
    const st = state.get(n.id) as State;
    const col = COLORS[n.kind][st];
    const shape = n.diamond ? "rhombus;" : "rounded=1;arcSize=18;";
    const strong = st === "active" ? "strokeWidth=4;shadow=1;" : "strokeWidth=2;shadow=0;";
    const size = n.diamond ? 12 : n.kind === "stage" ? 14 : 15;
    const sub = n.diamond || n.kind === "stage" ? 11 : 12;
    const value = `<b style="font-size:${size}px">${esc(n.title)}</b><br><span style="font-size:${sub}px">${esc(n.sub)}</span>`;
    cells.push(`<mxCell id="${n.id}" parent="1" style="${shape}whiteSpace=wrap;html=1;fillColor=${col.fill};strokeColor=${col.stroke};fontColor=${col.font};${strong}" value="${esc(value)}" vertex="1"><mxGeometry x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" as="geometry" /></mxCell>`);
  }

  edges.forEach(([from, to], i) => {
    const reached = state.get(to) !== "wait";
    const live = state.get(to) === "active";
    const kind = nodes.find((n) => n.id === to)?.kind === "setup" ? "#2563EB" : "#059669";
    const color = reached ? kind : "#D1D5DB";
    cells.push(`<mxCell id="e${i}" parent="1" source="${from}" target="${to}" edge="1" style="endArrow=block;endFill=1;html=1;rounded=0;strokeColor=${color};strokeWidth=${live ? 4 : 2};${live ? "flowAnimation=1;" : ""}"><mxGeometry relative="1" as="geometry" /></mxCell>`);
  });

  const name = index === 0 ? "start" : last ? "complete" : (ORDER[index] ?? []).join("+");
  return `  <diagram id="step-${String(index + 1).padStart(2, "0")}" name="${String(index + 1).padStart(2, "0")} ${name}">
    <mxGraphModel dx="1600" dy="900" grid="0" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="${W}" pageHeight="${H}" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        ${cells.join("\n        ")}
      </root>
    </mxGraphModel>
  </diagram>`;
}

const drawioPath = join(here, "kcc-lifecycle.drawio");
writeFileSync(drawioPath, `<mxfile host="app.diagrams.net" agent="kcc-framework make-lifecycle.ts">\n${ORDER.map((_, i) => page(i)).join("\n")}\n</mxfile>\n`);
console.log(`wrote kcc-lifecycle.drawio (${ORDER.length} pages)`);

// ---- optional: export pages and build the GIF ------------------------------------------------
if (process.argv.includes("--gif")) {
  const candidates = [process.env.DRAWIO, "C:\\Program Files\\draw.io\\draw.io.exe", "/Applications/draw.io.app/Contents/MacOS/draw.io", "drawio"].filter((p): p is string => !!p);
  const drawio = candidates.find((p) => p === "drawio" || existsSync(p));
  if (!drawio) {
    console.error("draw.io desktop not found. Set DRAWIO to its executable.");
    process.exit(1);
  }
  const frames = join(here, "frames");
  rmSync(frames, { recursive: true, force: true });
  mkdirSync(frames, { recursive: true });
  const list: string[] = [];
  for (let i = 0; i < ORDER.length; i++) {
    const out = join(frames, `frame-${String(i + 1).padStart(2, "0")}.png`);
    const r = spawnSync(drawio, ["--export", "--format", "png", "--page-index", String(i + 1), "--width", String(W), "--output", out, drawioPath], { stdio: "pipe", encoding: "utf8" });
    if (r.status !== 0 || !existsSync(out)) {
      console.error(`draw.io export of page ${i + 1} failed: ${r.stderr || r.stdout}`);
      process.exit(1);
    }
    list.push(`file '${out.replace(/\\/g, "/")}'`, `duration ${HOLD[i]}`);
    console.log(`exported page ${i + 1}/${ORDER.length}`);
  }
  // The concat demuxer needs the last file listed twice for its duration to count.
  list.push(`file '${join(frames, `frame-${String(ORDER.length).padStart(2, "0")}.png`).replace(/\\/g, "/")}'`);
  const listPath = join(frames, "frames.txt");
  writeFileSync(listPath, list.join("\n") + "\n");
  const gif = join(here, "kcc-lifecycle.gif");
  const f = spawnSync("ffmpeg", ["-y", "-f", "concat", "-safe", "0", "-i", listPath, "-vf", "fps=10,scale=1456:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=96[p];[s1][p]paletteuse=dither=none", "-loop", "0", gif], { stdio: "pipe", encoding: "utf8" });
  if (f.status !== 0) {
    console.error(`ffmpeg failed: ${f.stderr.slice(-600)}`);
    process.exit(1);
  }
  rmSync(frames, { recursive: true, force: true });
  console.log("wrote kcc-lifecycle.gif");
}
