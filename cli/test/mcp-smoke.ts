// End-to-end check of `kcc mcp` over stdio.
//   bun run test/mcp-smoke.ts <path to kcc binary> <workspace dir>
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const [bin, dir] = process.argv.slice(2);
if (!bin || !dir) {
  console.error("usage: bun run test/mcp-smoke.ts <kcc binary> <workspace dir>");
  process.exit(2);
}

function check(label: string, ok: boolean, detail = ""): void {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${detail ? ` - ${detail}` : ""}`);
  if (!ok) process.exitCode = 1;
}

const client = new Client({ name: "kcc-smoke", version: "0.0.0" });
await client.connect(new StdioClientTransport({ command: bin, args: ["mcp", "--dir", dir] }));

const resources = (await client.listResources()).resources;
check("resources listed", resources.length > 40, `${resources.length} resources`);
check("protocol resource present", resources.some((r) => r.uri === "kcc://protocol/auto-mode"));
check("agent ref resource present", resources.some((r) => r.uri === "kcc://agent/verifier/ref/review-template"));

const whole = await client.readResource({ uri: "kcc://contract/tool-contract" });
const part = await client.readResource({ uri: "kcc://contract/tool-contract#exit-codes" });
const textOf = (c: unknown): string => String((c as { text?: string } | undefined)?.text ?? "");
const wholeText = textOf(whole.contents[0]);
const partText = textOf(part.contents[0]);
check("heading read returns one section", partText.startsWith("## Exit codes") && !partText.includes("## Output") && partText.length < wholeText.length / 2, `${partText.length} of ${wholeText.length} chars`);

let missing = false;
try {
  await client.readResource({ uri: "kcc://contract/tool-contract#nope" });
} catch {
  missing = true;
}
check("unknown heading is an error", missing);

const tools = (await client.listTools()).tools;
check("tools listed", ["kcc_read", "kcc_check", "kcc_traceability", "kcc_wave_scope", "kcc_impl_lock", "kcc_quality_gate", "kcc_checkpoint", "kcc_handover", "kcc_run", "kcc_validate", "kcc_tailor"].every((n) => tools.some((t) => t.name === n)), `${tools.length} tools`);

const text = (r: unknown): string => String((r as { content?: { text?: string }[] }).content?.[0]?.text ?? "");

const outline = text(await client.callTool({ name: "kcc_read", arguments: { uri: "kcc://protocol/session-continuity", outline: true } }));
check("kcc_read outline", outline.includes("Session") || outline.split("\n").length > 3);

const checkOut = text(await client.callTool({ name: "kcc_check", arguments: { scope: "all" } }));
let contract = false;
try {
  const j = JSON.parse(checkOut) as { tool?: string; status?: string; violations?: unknown[] };
  contract = j.tool === "check-run-conformance" && typeof j.status === "string" && Array.isArray(j.violations);
} catch {
  contract = false;
}
check("kcc_check returns tool-contract JSON", contract, checkOut.slice(0, 120).replace(/\s+/g, " "));

const status = text(await client.callTool({ name: "kcc_run", arguments: { action: "status" } }));
check("kcc_run status", status.includes("status"));

const prompts = (await client.listPrompts()).prompts;
check("skills exposed as prompts", prompts.some((p) => p.name === "auto") && prompts.some((p) => p.name === "bug-report"), `${prompts.length} prompts`);
const prompt = await client.getPrompt({ name: "spec-plan", arguments: { args: "SPEC-042" } });
const body = String((prompt.messages[0]?.content as { text?: string }).text ?? "");
check("prompt arguments are substituted", body.includes("SPEC-042") && !body.includes("<ARGS>"));

await client.close();
