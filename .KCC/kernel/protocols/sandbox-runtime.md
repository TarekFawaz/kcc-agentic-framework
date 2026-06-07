---
# Functional fields
description: The per-harness Docker container that isolates an agent session from the host. Required when an agent matches the lethal trifecta; optional otherwise via `start-agent-session.ps1 --sandbox`.
inputs: An agent name, a target harness (claude | codex | opencode | generic), and a cell repository path.
outputs: A running sandboxed agent session and a one-line mount/network summary appended to the session trace.

# Obsidian metadata
title: Sandbox Runtime Protocol
aliases:
  - sandbox-runtime
  - kcc-sandbox
  - container-sandbox
tags:
  - kcc/kernel
  - framework/protocol
  - sandbox
  - security
  - kcc/v04
created: 2026-05-29
updated: 2026-06-02
version: 1.0.1
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Sandbox runtime

The per-harness container that isolates a KCC v0.4 agent session from the
host. This protocol governs *when* the container is required, *what* it
mounts and reaches, and *how* it integrates with the trifecta detector and
the critical-human-gate.

For the operational guide (Dockerfile layout, build/run examples, team-local
overrides), see [[../../sandbox/README|sandbox README]].

## What the sandbox runtime is

A minimal Debian-slim Docker image, one per harness, that:

- Bundles the harness CLI (Claude Code, Codex, OpenCode, or none for
  `generic`) plus bash and PowerShell Core so the framework's native `.sh`
  tools and Windows-compatible `.ps1` tools can both run inside.
- Bind-mounts the cell repository at `/workspace` and re-mounts
  `.KCC/kernel` and `.KCC/capabilities` read-only on top.
- Permits outbound DNS + HTTPS only to a known LLM-provider allowlist,
  blocks all inbound.
- Is launched by `.KCC/tools/start-agent-session.ps1 -Sandbox` (or
  automatically when the target agent is trifecta-tagged).

The sandbox is **not**:

- A replacement for `/critical-human-gate`. Containers limit blast
  radius if the gate is bypassed or an agent does something unexpected
  inside an approved scope - the gate still runs first.
- An LLM-provider isolation. LLM calls leave the sandbox by design.

## Trust model

| Zone | Trust | Notes |
|--|--|--|
| Workspace (`/workspace`) | trusted | The cell repo. Agents own it. |
| Host filesystem outside the workspace | untrusted | Never bind-mounted unless the human explicitly extends the launch command. |
| LLM provider endpoints | trusted edge | Reachable on the allowlist; treat the provider itself as a separate trust domain. |
| All other network egress | denied | No allowlist entry, no egress. |
| Inbound network | denied | No exposed ports. |

The default-deny posture means a hostile prompt cannot exfiltrate to an
arbitrary domain even after slipping past the gate - it can only reach
the LLM provider, which is the same channel the user is already using.

## Mount policy

| Host path                       | Container path                       | Mode | Why |
|--|--|--|--|
| `<cell repo>`                   | `/workspace`                         | rw   | Cell is the agent's work surface |
| `<cell repo>/.KCC/kernel`       | `/workspace/.KCC/kernel`             | ro   | Kernel is upstream - never mutated by agents |
| `<cell repo>/.KCC/capabilities` | `/workspace/.KCC/capabilities`       | ro   | Agent/skill specs are governance - never mutated mid-session |
| `$HOME/.docker`                 | (not mounted)                        | -    | Sandboxed agents never get host Docker socket access. |
| `$HOME/.ssh`                    | (not mounted)                        | -    | SSH keys stay on the host. |
| `$HOME/.aws`, `$HOME/.kube`     | (not mounted)                        | -    | Cloud and cluster credentials stay on the host. |

The cell repo bind mount is established first. The read-only re-mounts
on the two sub-paths are layered immediately after. This means an
implementer in the sandbox can still write to `src/`, `specs/`,
`Traces/`, etc., but cannot rewrite the agent or skill definitions it
is running under.

## Network policy

| Direction | Default | Override path |
|--|--|--|
| Outbound DNS | allowed | n/a |
| Outbound HTTPS to LLM allowlist | allowed | Edit the allowlist constant in `start-agent-session.ps1` or use a team-local Dockerfile. |
| Outbound HTTP/S to other hosts | denied | `--network host` (escape hatch; not recommended) |
| Inbound | denied | Add `-p host:container` to a team-local launcher. |

Recognised LLM hosts (current allowlist):

- `api.anthropic.com`
- `api.openai.com`
- `api.openrouter.ai`
- `api.mistral.ai`
- `generativelanguage.googleapis.com`
- `api.deepseek.com`

In corporate environments, layer an egress proxy by setting
`HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` env vars on the host before
invoking the launcher; the script forwards them into the container.

## When the sandbox is required vs optional

| Trigger | Sandbox |
|--|--|
| Agent frontmatter contains `lethal-trifecta-match: true` (set by maintainers after a `validate-kcc.ps1` warning) | **REQUIRED - automatically applied.** The launcher engages sandbox mode even if `-Sandbox` is omitted. |
| Human explicitly passes `-Sandbox` to `start-agent-session.ps1` | **REQUIRED - explicitly requested.** |
| Routine read-only sessions (`/spec-status`, `/butler-brief`) | **DEFAULT-OFF.** The session runs on the host. Per the user's call: trivial sessions skip the container to keep iteration fast. |
| First-time onboarding (`/solution-onboard`) on an untrusted repo | **RECOMMENDED.** Pass `-Sandbox` explicitly. |

The orchestrator should *prefer* sandbox-on for any session involving
`web`-capable agents on first contact with an unknown codebase.

## Integration with critical-human-gate

Sandbox mode and the gate are **complementary, not alternatives**:

1. Trifecta-flagged agent is selected.
2. `start-agent-session.ps1` sees `lethal-trifecta-match: true`, builds
   (if needed) and launches the harness inside the sandbox container.
3. The harness loads the agent's skill chain.
4. Before the first external-comms action, the orchestrator invokes
   `/critical-human-gate` with the trifecta payload (per
   [[lethal-trifecta]]).
5. Human chooses `approve` / `revise` / `abort`.
6. The action proceeds (or doesn't) **inside** the sandbox.

If the gate is approved but the agent then attempts an action that
breaches the sandbox boundary (writes to a path outside `/workspace`,
calls an off-allowlist domain), the container blocks it before the host
sees the syscall. The breach attempt SHOULD be logged to
`coordination/backchannel.jsonl` as `sandbox-breach-blocked`.

## Conventions for team-local overrides

Per the cells convention, organisations layer their own image on top:

- File location: `<cell>/local/sandbox/Dockerfile.{harness}` (preserved
  by `sync-adapters.ps1`).
- Resolution order: launcher checks `<cell>/local/sandbox/` first, then
  `.KCC/sandbox/`.
- Common reasons to override:
  - Corporate CA bundle for an egress proxy.
  - Pre-baked language toolchain (Rust, .NET, Java) the implementer
    needs without bloating the kernel image.
  - Vendored `pwsh` modules.
  - Tighter network allowlist (drop hosts the team does not use).

A team override SHOULD `FROM` the matching kernel image
(`kcc-sandbox-{harness}:latest`) so kernel updates flow downstream
automatically.

## Linux/macOS vs Windows host considerations

| Host | Notes |
|--|--|
| Linux | Native Docker Engine. Fastest. Bind mounts honour host UID/GID directly; run with `--user $(id -u):$(id -g)` if you care about file ownership inside the workspace. |
| macOS | Docker Desktop runs a Linux VM; bind mounts go through gRPC FUSE - large repos are slow. Consider `:cached` mount mode for hot paths. |
| Windows | Docker Desktop with WSL2 backend. The launcher converts host paths (`C:\Work\...`) into WSL paths (`/mnt/c/Work/...`) automatically when invoking `docker run`. PowerShell on the host stays PowerShell 5.1 unless `pwsh` is installed - the script targets both. |

## Limitations

- **LLM API calls still leave the sandbox.** Anything the agent decides
  to send to its provider is sent. This protocol is about host
  filesystem and shell isolation, not provider isolation.
- **The agent inside has full /workspace.** Sandbox does not partition
  per-agent - an implementer in the sandbox sees the same `/workspace`
  as a verifier would.
- **Image rebuilds are not automatic.** If `.KCC/sandbox/Dockerfile.*`
  changes, run `docker rmi kcc-sandbox-{harness}:latest` to force a
  rebuild on next launch. (A future enhancement could hash the
  Dockerfile and re-tag on drift.)
- **No GPU passthrough by default.** Add `--gpus all` in a team-local
  launcher if your harness needs it.

## Related

- [[lethal-trifecta]] - the detector that decides automatic-sandbox.
- [[critical-human-gate]] - the human approval that runs *inside* the
  sandbox.
- [[backchannel]] - where `sandbox-launched`, `sandbox-exited`, and
  `sandbox-breach-blocked` events land.
- [[../../sandbox/README|sandbox README]] - operational guide with
  build/run examples.
