import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  GetPromptRequestSchema,
  ListPromptsRequestSchema,
  ListResourceTemplatesRequestSchema,
  ListResourcesRequestSchema,
  ListToolsRequestSchema,
  ReadResourceRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { join, resolve } from "node:path";
import { readJson } from "../fsutil";
import { findRoot, runTool } from "../platform";
import { readSettings } from "../settings";
import { CLI_VERSION } from "../version";
import { Content, headings, parseSkill, section } from "./content";

type Args = Record<string, unknown>;
type Prop = { type: string; description: string; enum?: string[] };

interface ToolDef {
  name: string;
  description: string;
  props: Record<string, Prop>;
  required?: string[];
  /** Builds the script name and its arguments (bash spelling). */
  script?: (a: Args) => [string, string[]];
  /** For tools answered without a script. */
  local?: (a: Args, root: string, content: Content) => string;
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v.trim() !== "" ? v.trim() : undefined);
const opt = (flag: string, v: unknown): string[] => (str(v) ? [flag, str(v) as string] : []);
const flag = (name: string, v: unknown): string[] => (v === true ? [name] : []);

const SPEC: Prop = { type: "string", description: "Spec id, for example SPEC-003. Omit to cover every spec." };

const TOOLS: ToolDef[] = [
  {
    name: "kcc_read",
    description: "Read KCC framework content: a whole document, or one section when `heading` is given (much cheaper). With `outline: true` it returns only the document's headings.",
    props: {
      uri: { type: "string", description: "kcc://protocol/{name}, kcc://dialect/{name}, kcc://contract/{name}, kcc://template/{path}, or kcc://agent/{agent}/ref/{topic}" },
      heading: { type: "string", description: "Heading text or its slug, for example 'Hard stops' or 'hard-stops'." },
      outline: { type: "boolean", description: "Return the list of headings instead of the text." },
    },
    required: ["uri"],
    local: (a, _root, content) => readUri(content, String(a.uri) + (str(a.heading) ? `#${encodeURIComponent(str(a.heading) as string)}` : ""), a.outline === true),
  },
  {
    name: "kcc_check",
    description: "Run check-run-conformance: verifies idea, spec, plan, review, and bug artifacts against the KCC layout. Returns the tool-contract JSON.",
    props: { scope: { type: "string", description: "Sub-check to run.", enum: ["all", "idea", "specs", "plan", "review", "bugs"] }, spec: SPEC },
    script: (a) => ["check-run-conformance", ["--json", ...opt("--scope", a.scope), ...opt("--spec", a.spec)]],
  },
  {
    name: "kcc_traceability",
    description: "Run check-traceability: every acceptance criterion maps to a Test ID, a real test, and a PASS. Returns the tool-contract JSON.",
    props: { spec: SPEC },
    script: (a) => ["check-traceability", ["--json", ...opt("--spec", a.spec)]],
  },
  {
    name: "kcc_wave_scope",
    description: "Run check-wave-scope: the files changed by a wave stay inside what its backlog items declared. Returns the tool-contract JSON.",
    props: { spec: { type: "string", description: "Spec id, for example SPEC-003." }, wave: { type: "string", description: "Wave number from plan.md." }, base: { type: "string", description: "Git ref or manifest to compare against. Default: the newest restore point." } },
    required: ["spec", "wave"],
    script: (a) => ["check-wave-scope", ["--json", ...opt("--spec", a.spec), ...opt("--wave", String(a.wave ?? "")), ...opt("--base", a.base)]],
  },
  {
    name: "kcc_impl_lock",
    description: "Run check-impl-lock: source files may change only once a spec has an approved plan and budget. Returns the tool-contract JSON.",
    props: { path: { type: "string", description: "A file path to test." }, staged: { type: "boolean", description: "Test the staged git changes instead." } },
    script: (a) => ["check-impl-lock", ["--json", ...opt("--path", a.path), ...flag("--staged", a.staged)]],
  },
  {
    name: "kcc_quality_gate",
    description: "Run quality-gate: build, lint, tests, coverage floor, secrets, dependency audit, and SAST for the detected stacks. Exit 3 (status deferred) means a scanner is missing; that is never a pass. Returns the tool-contract JSON.",
    props: { spec: SPEC, fast: { type: "boolean", description: "Secrets scan of staged files only." }, scope: { type: "string", description: "Limit to one check group." } },
    script: (a) => ["quality-gate", ["--json", ...opt("--spec", a.spec), ...opt("--scope", a.scope), ...flag("--fast", a.fast)]],
  },
  {
    name: "kcc_checkpoint",
    description: "Write a restore point (coordination/checkpoints) so the run can be resumed later or on another harness.",
    props: { reason: { type: "string", description: "Why the restore point is written, for example manual, wave-done, spec-reviewed." }, next_action: { type: "string", description: "What to do first after a resume." }, dry_run: { type: "boolean", description: "Report only; write nothing." } },
    required: ["reason"],
    script: (a) => ["kcc-checkpoint", ["--json", ...opt("--reason", a.reason), ...opt("--next-action", a.next_action), ...flag("--dry-run", a.dry_run)]],
  },
  {
    name: "kcc_handover",
    description: "Prepare a handover of the current run to another harness. It writes the handover envelope and prints the start command; it never launches the other harness.",
    props: { to: { type: "string", description: "Target harness.", enum: ["claude", "codex", "opencode", "generic"] }, dry_run: { type: "boolean", description: "Report only; write nothing." } },
    required: ["to"],
    script: (a) => ["kcc-handover", ["--json", ...opt("--to", a.to), ...flag("--dry-run", a.dry_run)]],
  },
  {
    name: "kcc_run",
    description: "The deterministic lifecycle driver. `status` reads the current run; `plan` lists the states a run would execute and writes nothing; `answer` answers the open human gate. Starting or resuming a run is done from a terminal with `kcc run`, not through this tool.",
    props: { action: { type: "string", description: "What to do.", enum: ["status", "plan", "answer"] }, input: { type: "string", description: "For plan: an idea, a path, IDEA-ID, SPEC-ID, or all." }, answer: { type: "string", description: "For answer: the chosen option of the open gate." } },
    required: ["action"],
    script: (a) => {
      if (a.action === "plan") return ["kcc-run", ["--json", "--dry-run", ...opt("--input", a.input)]];
      return ["kcc-run", ["--json", ...opt("--answer", a.answer)]];
    },
    local: (a, root) => (a.action === "status" ? JSON.stringify(readJson(join(root, "coordination", "run", "run.json")) ?? { status: "no run recorded" }, null, 2) : ""),
  },
  {
    name: "kcc_validate",
    description: "Run validate-kcc: checks the .KCC layout, required files, frontmatter, and the contract lint. Returns its text report.",
    props: {},
    script: () => ["validate-kcc", []],
  },
  {
    name: "kcc_tailor",
    description: "Show how this workspace is tailored: the recorded solution context, kept dialects, and dropped agents and skills. Changing it is done from a terminal with `kcc tailor`.",
    props: {},
    local: (_a, root) => JSON.stringify(readSettings(root)?.tailoring ?? { tailored: false }, null, 2),
  },
];

function readUri(content: Content, uri: string, outline = false): string {
  const hash = uri.indexOf("#");
  const base = hash >= 0 ? uri.slice(0, hash) : uri;
  const frag = hash >= 0 ? uri.slice(hash + 1) : "";
  const entry = content.catalog().find(([u]) => u === base);
  const text = entry ? content.read(entry[1]) : undefined;
  if (text === undefined) throw new Error(`unknown resource ${base}. List resources to see what exists.`);
  if (outline) return headings(text).map((h) => `${"  ".repeat(h.level - 1)}${h.title}`).join("\n") + "\n";
  if (!frag) return text;
  const part = section(text, frag);
  if (part === undefined) throw new Error(`no heading '${decodeURIComponent(frag)}' in ${base}. Headings: ${headings(text).map((h) => h.title).join(" | ")}`);
  return part;
}

export async function serveMcp(argv: string[]): Promise<number> {
  const i = argv.indexOf("--dir");
  const root = findRoot(resolve(i >= 0 ? (argv[i + 1] ?? ".") : process.cwd()));
  const content = new Content(root);
  const server = new Server({ name: "kcc", version: CLI_VERSION }, { capabilities: { resources: {}, tools: {}, prompts: {} } });

  server.setRequestHandler(ListResourcesRequestSchema, async () => ({
    resources: content.catalog().map(([uri, rel, description]) => ({ uri, name: rel, description, mimeType: rel.endsWith(".md") ? "text/markdown" : "text/plain" })),
  }));

  server.setRequestHandler(ListResourceTemplatesRequestSchema, async () => ({
    resourceTemplates: [
      { uriTemplate: "kcc://protocol/{name}#{heading}", name: "Protocol section", description: "One section of a protocol. Prefer this over the whole document.", mimeType: "text/markdown" },
      { uriTemplate: "kcc://dialect/{name}#{heading}", name: "Dialect section", description: "One section of a development dialect.", mimeType: "text/markdown" },
      { uriTemplate: "kcc://contract/{name}#{heading}", name: "Contract section", description: "One section of a contract.", mimeType: "text/markdown" },
      { uriTemplate: "kcc://agent/{name}/ref/{topic}", name: "Agent reference", description: "An on-demand template or reference for one agent.", mimeType: "text/markdown" },
    ],
  }));

  server.setRequestHandler(ReadResourceRequestSchema, async (req) => ({
    contents: [{ uri: req.params.uri, mimeType: "text/markdown", text: readUri(content, req.params.uri) }],
  }));

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: { type: "object" as const, properties: t.props, required: t.required ?? [] } })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const tool = TOOLS.find((t) => t.name === req.params.name);
    const args = (req.params.arguments ?? {}) as Args;
    const fail = (text: string) => ({ content: [{ type: "text" as const, text }], isError: true });
    if (!tool) return fail(`unknown tool ${req.params.name}`);
    for (const r of tool.required ?? []) if (str(String(args[r] ?? "")) === undefined) return fail(`missing required argument '${r}'`);
    try {
      if (tool.local) {
        const text = tool.local(args, root ?? "", content);
        if (text !== "" || !tool.script) return { content: [{ type: "text" as const, text }] };
      }
      if (!root) return fail("this folder has no .KCC/ workspace. Run 'kcc init' in the project first.");
      const [name, sargs] = (tool.script as NonNullable<ToolDef["script"]>)(args);
      const r = runTool(root, name, [...sargs, "--repo-root", root], { capture: true });
      const text = (r.stdout.trim() || r.stderr.trim() || `(no output, exit ${r.status})`) + (r.stdout.trim().startsWith("{") ? "" : `\n(exit ${r.status})`);
      // Exit 1 (violations) and 3 (deferred) are results the caller routes on; only 2 is a failed call.
      return { content: [{ type: "text" as const, text }], isError: r.status === 2 };
    } catch (e) {
      return fail((e as Error).message);
    }
  });

  const skillDocs = () => content.skills().map((n) => parseSkill(n, content.read(`capabilities/skills/${n}.md`) ?? ""));

  server.setRequestHandler(ListPromptsRequestSchema, async () => ({
    prompts: skillDocs().map((s) => ({ name: s.name, description: s.description, arguments: [{ name: "args", description: "What you would type after the slash command.", required: false }] })),
  }));

  server.setRequestHandler(GetPromptRequestSchema, async (req) => {
    const skill = skillDocs().find((s) => s.name === req.params.name);
    if (!skill) throw new Error(`unknown prompt ${req.params.name}`);
    const text = skill.body.split(skill.placeholder).join(req.params.arguments?.args ?? "");
    return { description: skill.description, messages: [{ role: "user" as const, content: { type: "text" as const, text } }] };
  });

  await server.connect(new StdioServerTransport());
  // Stay alive until the client closes the pipe.
  await new Promise<void>((done) => {
    process.stdin.on("end", done);
    process.stdin.on("close", done);
  });
  return 0;
}
