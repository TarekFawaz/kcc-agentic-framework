# DSH hardened profile package (Plan 08, Task 5)

The DeepSeek Harness adapter's **policy-guard profile/plugin** — the piece
the generated skills alone can never provide.  Skill generation documents
the worker boundary; this package **enforces** it on fresh sessions.

## Layout

| Path | Purpose |
|------|---------|
| `plugin/` | `kcc-dsh-policy-gate` bundle: monotonic Cordis guard (real `tools/pre-execute` + `ctx.tools.guard`) + the exact wrappers `kcc_policy_exec`, `kcc_policy_write`, `kcc_harness_status` |
| `profile/` | `kcc-autobuild` profile package: bundle manifest (base + headless + gate bundle) and the hardened patch layer (sandbox `workspace-write`, approval `never`, permission preset, model route, gate wiring, plan-mode disabled) |
| `gate/` | signed policy bundle provisioning (`sign-policy.py`, `README.md`) |
| `install.sh`, `install.ps1` | **explicit** installer: copies the profile into `$DSH_HOME/profiles/kcc-autobuild` and installs the repo adapter via `dsh plugin --profile kcc-autobuild add` |

## Install (explicit only)

```bash
bash .KCC/adapters/dsh/install.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\adapters\dsh\install.ps1
```

`framework-init` **prints** this command by default; it never silently
mutates `DSH_HOME`.  Add `--install-dsh-profile` (sh) /
`-InstallDshProfile` (ps1) only to actually run the installer, and choose
`--force` / `-Force` only to replace an existing profile.

## Proof (disposable, gated)

```bash
# preflight (never a proof):
kcc-autobuild harness doctor dsh --live=false --template kcc-autobuild
# live proof: one disposable copy, one kcc_harness_status call, exactly one
# KCC_DSH_STATUS: {"sandbox":"workspace-write","approval":"never","guard":"kcc-policy-gate"} line:
kcc-autobuild harness doctor dsh --live --template kcc-autobuild
```

Hardened capabilities (`approval_mode=NEVER`,
`mutation_enforcement=KCC_POLICY_GATE`) are granted only after such a
live proof — never by the presence of these files.

## Hardening scope

- Applies **only to fresh sessions**: the installer copies the profile only
  when explicitly invoked; `framework-init` prints commands by default.
- Live doctor/smoke runs only in **disposable** profiles/workspaces
  (temporary `DSH_HOME`, profile files copied, `node_modules` symlinked).
- The gate policy bundle + owner-only secret are provisioned
  machine-locally by `gate/sign-policy.py` (default: **empty policy =
  fail closed**); no secret is committed and no secret travels on a CLI
  argument.

## Contractor notes

- The plugin's own `node_modules/@deepseek-ai` is linked by the installer
  to the dsh installation scope (mirrors dsh-agentmemory's checkout);
  it is git-ignored.
- The model route is pinned in the profile patch (`deepseek-official`) so
  the disposable doctor home works without a user `settings.yaml`.
