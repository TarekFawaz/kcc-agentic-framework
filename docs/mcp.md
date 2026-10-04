# KCC Over MCP

`kcc mcp` is a local Model Context Protocol server. It runs on your own
machine, started by your harness, and talks over stdio. It opens no network
port and is not shared with anyone: each developer runs their own. Sharing
capabilities and policy across teams in an organisation is a separate layer
that is planned but not built (see `docs/plans/PLAN-distribution-mcp.md`,
epic E6).

The protocol is specified in `.KCC/kernel/protocols/mcp.md`.

## Why use it

- **Cheaper reads.** An agent asks for one section of a protocol
  (`kcc://protocol/auto-mode#hard-stops`) instead of loading the file.
- **One way to call the gates** from Claude Code, Codex, and OpenCode, with
  the same JSON result.
- **Skills everywhere.** Every KCC skill is available as an MCP prompt, also
  in harnesses that have no file-based skills.

## Set up

```text
kcc init --mcp          # during first setup
kcc mcp --register      # in an existing workspace
```

| Harness | File written |
|--|--|
| Claude Code | `.mcp.json` |
| Codex CLI | `.codex/config.toml` (`[mcp_servers.kcc]`) |
| OpenCode | `opencode.json` (`mcp.kcc`) |

Other servers already listed in those files are kept. Restart the harness
session and approve the server when it asks. `kcc` must be on PATH.

## Resources

| URI | Content |
|--|--|
| `kcc://protocol/{name}` | a protocol |
| `kcc://dialect/{name}` | a development dialect |
| `kcc://contract/{name}` | a contract |
| `kcc://template/{path}` | a template |
| `kcc://agent/{agent}/ref/{topic}` | an on-demand agent reference |

Add `#heading` for one section, using the heading text or its slug:
`kcc://contract/tool-contract#exit-codes`.

In a tailored workspace the server serves the tailored content: dropped
dialects are not listed.

## Tools

| Tool | Does |
|--|--|
| `kcc_read` | Reads a resource, one heading of it, or its outline |
| `kcc_check` | Conformance of idea, spec, plan, review, and bug artifacts |
| `kcc_traceability` | Acceptance criterion -> Test ID -> test -> PASS |
| `kcc_wave_scope` | A wave's changes stay inside its declared files |
| `kcc_impl_lock` | Source may change only with an approved plan and budget |
| `kcc_quality_gate` | Build, lint, tests, coverage, secrets, dependencies, SAST |
| `kcc_checkpoint` | Writes a restore point |
| `kcc_handover` | Prepares a handover to another harness |
| `kcc_run` | Run status, a dry-run plan, or the answer to an open gate |
| `kcc_validate` | Framework validator |
| `kcc_tailor` | Shows the applied tailoring |

Each gate tool returns the script's own JSON
(`.KCC/kernel/contracts/tool-contract.md`). Violations (`status: fail`) and
a missing scanner (`status: deferred`) are results to act on, not failed
calls. No tool pushes, deploys, installs software, or starts a harness;
starting a run and changing the tailoring stay terminal commands.

## Prompts

Every skill appears as a prompt with one optional argument, `args`. In
Claude Code: `/mcp__kcc__spec-plan SPEC-003`.

## Check that it works

```bash
cd cli
bun run test/mcp-smoke.ts dist/kcc /path/to/workspace
```

The script connects as an MCP client and checks the resource list, a
section read, the tool list, a gate call, and prompt substitution.
