---
title: KCC v0.4 Sandbox Runtime
tags:
  - framework/documentation
  - sandbox
  - security
  - kcc/v04
created: 2026-05-29
updated: 2026-06-02
version: 1.0.1
status: active
---

# KCC v0.4 sandbox runtime

Per-harness Docker containers that isolate an agent session from the host
filesystem and host shell. This is the **enterprise security boundary** for
running framework agents on machines where untrusted prompts, untrusted files,
or external research are involved.

For the normative protocol (trust model, mount table, network policy, gate
integration), see [[../kernel/protocols/sandbox-runtime|sandbox-runtime]].

## Why the sandbox exists

- Many agents in this framework combine `read`, `web`, and `exec`. That is
  the [[../kernel/protocols/lethal-trifecta|lethal trifecta]]. Untrusted text
  + private repo data + external comms is the canonical prompt-injection
  exfiltration path.
- Even with `confidence-gate: required`, the host shell remains a target.
- Containers do not replace the gate - they constrain blast radius if the
  gate is bypassed or an agent decides to be creative inside an approved
  scope.

## Dockerfile layout

Each `Dockerfile.{harness}` follows the same minimal pattern:

| Stage | Content |
|--|--|
| Base  | `debian:stable-slim` |
| Runtime | `node 20`, `git`, `ca-certificates`, `curl`, `gnupg` |
| Shell | bash plus PowerShell Core (`pwsh`) so native `.sh` tools and Windows-compatible `.ps1` tools can both run inside |
| Harness | The harness CLI (`@anthropic-ai/claude-code`, `@openai/codex`, `opencode-ai`) installed globally via npm; `Dockerfile.generic` installs none |
| Workdir | `/workspace` |
| Mount  | `VOLUME ["/workspace"]` - host cell repo is bind-mounted here |
| Net    | No exposed ports. Outbound only, restricted by the launch script |
| CMD    | The harness binary (`claude` / `codex` / `opencode` / `pwsh` for generic) |

Images stay small (~250-400 MB each). They are built lazily on the first
`start-agent-session.ps1 --sandbox` invocation per harness and cached as
`kcc-sandbox-{harness}:latest`.

## Default mount policy

When invoked via `.KCC/tools/start-agent-session.ps1 --sandbox`:

| Host path                       | Container path                       | Mode | Why |
|--|--|--|--|
| `<cell repo>`                   | `/workspace`                         | rw   | Cell is the agent's work surface |
| `<cell repo>/.KCC/kernel`       | `/workspace/.KCC/kernel`             | ro   | Kernel is upstream - never mutated by agents |
| `<cell repo>/.KCC/capabilities` | `/workspace/.KCC/capabilities`       | ro   | Agent/skill specs are governance - never mutated mid-session |

The cell repo bind mount is established first; the read-only re-mounts on the
two sub-paths are applied immediately after.

## Default network policy

- **Outbound DNS**: allowed.
- **Outbound HTTPS**: allowed to the LLM provider hosts the launch script
  recognises:
  - `api.anthropic.com`
  - `api.openai.com`
  - `api.openrouter.ai`
  - `api.mistral.ai`
  - `generativelanguage.googleapis.com`
  - `api.deepseek.com`
- **Inbound**: blocked. No exposed ports.
- Override: pass `--network host` or build a team-local image; see below.

The container does not implement a per-host firewall - it uses
`--dns` + `--add-host` for known LLM hosts and lets Docker's default
network drop inbound. On hardened sites, layer your own egress proxy
(`HTTP_PROXY` / `HTTPS_PROXY` env vars passed through by the launcher).

## How `--sandbox` works in `start-agent-session.ps1`

1. The script accepts `-Sandbox` as a switch (default off).
2. If `-Sandbox` is set OR if the target agent's
   `.KCC/capabilities/agents/{name}.md` frontmatter contains
   `lethal-trifecta-match: true`, sandbox mode engages.
3. The script resolves `.KCC/sandbox/Dockerfile.{harness}`.
4. If the image `kcc-sandbox-{harness}:latest` is not cached, it builds:
   `docker build -t kcc-sandbox-{harness}:latest .KCC/sandbox -f .KCC/sandbox/Dockerfile.{harness}`
5. It runs the container with the mount and network policies above and
   launches the harness inside.
6. On exit, it prints a one-line summary of the mounts and network used,
   for the session trace.

## Lethal Trifecta auto-sandbox

`validate-kcc.ps1` already flags agents that match all three trifecta legs
(see [[../kernel/protocols/lethal-trifecta]]). For any such agent, the
recommended mitigation is to add `lethal-trifecta-match: true` to its
frontmatter so `start-agent-session.ps1` *automatically* sandboxes any
session targeting that agent - even when `-Sandbox` is not passed.

A trifecta-tagged agent still passes through `/critical-human-gate` before
its first external-comms action, so the human sees both the sandbox banner
and the gate prompt.

## Extending with team-local Dockerfiles

Per the cells convention, team-local sandbox images live under
`<cell>/local/sandbox/Dockerfile.*` and are preserved by
`sync-adapters.ps1`. The launcher first looks in `<cell>/local/sandbox/`
and falls back to `.KCC/sandbox/` if no override is present. Use this for:

- Custom CA bundles for corporate egress proxies.
- Pre-baked language toolchains the implementer needs but you do not want
  to bloat the kernel image with (Rust, .NET, Java).
- Vendored `pwsh` modules.

## Build + run examples

Build all four images by hand (the launcher does this lazily on first use):

```powershell
docker build -t kcc-sandbox-claude:latest    .KCC/sandbox -f .KCC/sandbox/Dockerfile.claude
docker build -t kcc-sandbox-codex:latest     .KCC/sandbox -f .KCC/sandbox/Dockerfile.codex
docker build -t kcc-sandbox-opencode:latest  .KCC/sandbox -f .KCC/sandbox/Dockerfile.opencode
docker build -t kcc-sandbox-generic:latest   .KCC/sandbox -f .KCC/sandbox/Dockerfile.generic
```

Run a sandboxed Claude session for the `idea-interrogator` agent:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 `
    -Harness claude -Agent idea-interrogator -Sandbox
```

Run a sandboxed Codex session with an explicit prompt file:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 `
    -Harness codex -Agent planner -Sandbox `
    -PromptFile .\coordination\prompts\SPEC-003-planner.md
```

Inspect a container interactively (debugging only - bypasses the
launcher's network policy):

```powershell
docker run --rm -it -v "${PWD}:/workspace" kcc-sandbox-claude:latest pwsh
```

## Limitations

- LLM API calls still leave the sandbox by design - this is host isolation,
  not provider isolation. Treat the LLM provider as a separate trust domain.
- Docker Desktop on Windows/macOS adds a VM hop; performance for large
  builds is noticeably slower than on Linux hosts running Docker Engine
  directly.
- The sandbox does **not** sandbox the harness from itself - an agent
  running inside still has full read/write to `/workspace`. The boundary
  is host vs. workspace, not agent vs. workspace.

## Related

- [[../kernel/protocols/sandbox-runtime|sandbox-runtime protocol]]
- [[../kernel/protocols/lethal-trifecta|lethal-trifecta protocol]]
- [[../kernel/protocols/critical-human-gate|critical-human-gate protocol]]
- [[../tools/start-agent-session.ps1|start-agent-session.ps1]]
---
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
See [LICENSE](./LICENSE).