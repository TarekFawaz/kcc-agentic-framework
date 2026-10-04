import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { readJson, writeJson } from "../fsutil";

const CODEX_BLOCK = '\n[mcp_servers.kcc]\ncommand = "kcc"\nargs = ["mcp"]\n';

/**
 * Registers the local `kcc mcp` server with each harness that has a project
 * config. Existing entries are left alone; a config that cannot be parsed is
 * not touched and the snippet is printed instead.
 */
export function registerMcp(root: string): void {
  // Claude Code: project-scoped .mcp.json
  const mcpJson = join(root, ".mcp.json");
  const claude = existsSync(mcpJson) ? readJson<{ mcpServers?: Record<string, unknown> }>(mcpJson) : {};
  if (!claude) console.log('Could not parse .mcp.json. Add by hand: "mcpServers": { "kcc": { "command": "kcc", "args": ["mcp"] } }');
  else if (claude.mcpServers?.kcc) console.log("MCP: .mcp.json already lists kcc.");
  else {
    claude.mcpServers = { ...claude.mcpServers, kcc: { command: "kcc", args: ["mcp"] } };
    writeJson(mcpJson, claude);
    console.log("MCP: registered kcc in .mcp.json (Claude Code).");
  }

  // Codex CLI: sync-adapters writes .codex/config.toml once and never overwrites it.
  const codex = join(root, ".codex", "config.toml");
  if (existsSync(codex)) {
    const text = readFileSync(codex, "utf8");
    if (text.includes("[mcp_servers.kcc]")) console.log("MCP: .codex/config.toml already lists kcc.");
    else {
      writeFileSync(codex, text.replace(/\s*$/, "\n") + CODEX_BLOCK);
      console.log("MCP: registered kcc in .codex/config.toml (Codex CLI).");
    }
  }

  // OpenCode: opencode.json at the workspace root.
  const oc = join(root, "opencode.json");
  if (existsSync(oc)) {
    const cfg = readJson<{ mcp?: Record<string, unknown> }>(oc);
    if (!cfg) console.log('Could not parse opencode.json. Add by hand: "mcp": { "kcc": { "type": "local", "command": ["kcc", "mcp"], "enabled": true } }');
    else if (cfg.mcp?.kcc) console.log("MCP: opencode.json already lists kcc.");
    else {
      cfg.mcp = { ...cfg.mcp, kcc: { type: "local", command: ["kcc", "mcp"], enabled: true } };
      writeJson(oc, cfg);
      console.log("MCP: registered kcc in opencode.json (OpenCode).");
    }
  }
}
