# Gate policy signing (Plan 08, Task 5)

The DSH wrappers (`kcc_policy_write` / `kcc_policy_exec`) pipe the
untrusted operation request to the local Python policy gate over stdin.
The gate reloads the durable run, rejects stale leases, **verifies the
signed policy bundle** and only then lets PolicyToolGate mint/audit a
unique decision token and execute.

## Files created by `sign-policy.py`

| File | Purpose |
|------|---------|
| `policy-bundle.json` | canonical HMAC-SHA256 signed `PolicyBundle` (format marker + exact rule triples) |
| `.gate-secret` | owner-only (0600) HMAC key; its *value* is never printed or passed on a CLI |

The secret is **not in the repository** and never travels on a command
line: the gate reads the file referenced by `--secret-file`, and the
plugin/profile refer to it by path.  The bundle references it by
signature only, and a tampered bundle fails closed (signature mismatch).

## Default = fail closed

```bash
python .KCC/adapters/dsh/gate/sign-policy.py --out-dir GATE_DIR
```

provisions an **empty policy** — every operation is DENIED until KCC
signs the real policy:

```bash
python .KCC/adapters/dsh/gate/sign-policy.py --out-dir GATE_DIR \
    --rules-file kcc-policy-rules.json
```

Each rule is an exact `(operation, resource, data_class)` triple
(`ALLOWED` / `DENIED`); `write` resources are canonical workspace-relative
paths, `exec` resources are plain program names.

## Rotation

Re-sign with the existing key so previously minted decision tokens stay
audit-consistent:

```bash
python .KCC/adapters/dsh/gate/sign-policy.py --out-dir GATE_DIR \
    --secret-file GATE_DIR/.gate-secret --rules-file (...) 
```
