# kcc-dsh-policy-gate

KCC policy gate bundle for DeepSeek Harness (Plan 08, Task 5).  Mounted as
the `kcc-policy-gate` composition row of the hardened `kcc-autobuild`
profile, it:

1. registers a **monotonic Cordis execution guard** through the real
   `tools/pre-execute` waterfall via `ctx.tools.guard(...)`;
2. registers exactly three KCC tools:

   | Tool | Purpose |
   |---|---------|
   | `kcc_harness_status` | read-only sandbox/approval/guard probe (doctor + smoke evidence) |
   | `kcc_policy_write` | governed write wrapper (the only mutation path) |
   | `kcc_policy_exec` | governed process wrapper (the only process path) |

## Exact fail-closed allowlist

Allow: native `read`, `read_image`, `glob`, `grep`, `todo_write` plus the
three exact KCC wrappers above.  **Deny** (no prompt, no escalation):
`bash`, `pwsh`, `terminal`, `write`, `edit`, `str_replace`,
`job_kill`, `web_search`, `web_fetch`, `create_goal`, `update_goal`,
`subagent*`, `workflow`, `ralph`, `run_code`, `cordis_*`, `mcp__*` and
every unknown tool.  There is no controller/resume wrapper: KCC owns
controller, status and resume.

The guard is the enforcement: a guard has no allow result, so no listener
ordering can turn a denial back into permission.  Visibility restriction
is deliberately not applied at the host layer (the runtime refuses a
context-global `tools.restrict`), so every denied tool stays callable
*and* denied without a prompt.  No fake session tag: the guard runs in
the runtime's own pre-execute/guard pipeline.

## Wrappers

`kcc_policy_write` / `kcc_policy_exec` derive the workspace from the
calling session (`exec.agent.session`), bind the request to the KCC
run/task/lease identity from the task handoff pack, and pipe the
untrusted operation request to the **local Python policy gate** over
stdin: `kcc-autobuild gate-write` / `kcc-autobuild gate-exec`
(CLI internal commands, never user-facing).  The gate reloads the durable
run, rejects stale leases, verifies the signed policy bundle, and
PolicyToolGate mints/audits a unique decision token **before** the
executor runs.  The command line carries only fixed configuration
(`--bundle`, `--secret-file`, `--timeout`) — never model input, never a
raw secret.

## Config

| Key | Default | Meaning |
|-----|---------|---------|
| `gateCommand` | `kcc-autobuild` | local CLI that serves the gate |
| `gateBundleFile` | `""` | signed policy bundle (empty = fail closed) |
| `gateSecretFile` | `""` | owner-only HMAC secret file (empty = env `KCC_AUTOBUILD_POLICY_SECRET_FILE`) |
| `gateTimeoutMs` | 600000 | per-request budget |

The `kcc-autobuild` profile layer (`.KCC/adapters/dsh/profile/cordis.patch.yml`,
install-generated) fills these with machine-local absolutes.

## Install (bundle)

```bash
dsh plugin --profile kcc-autobuild add "$(pwd)/.KCC/adapters/dsh/plugin"
```

or use the profile installer: `bash .KCC/adapters/dsh/install.sh` /
`.\KCC\adapters\dsh\install.ps1`.
