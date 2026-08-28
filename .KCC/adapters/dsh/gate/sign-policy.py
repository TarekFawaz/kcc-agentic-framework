#!/usr/bin/env python3
"""Provision the signed policy bundle + owner-only secret of the KCC gate.

Plan 08, Task 5: the DSH worker wrappers call the local Python policy gate
(``kcc-autobuild gate-write`` / ``gate-exec``), which verifies a signed
:class:`kcc_autobuild.policy.PolicyBundle` before letting PolicyToolGate
mint/audit a decision token and execute.  The signing secret never lives
in the repository and never appears on a command line: this script writes
a randomly generated owner-only secret (mode 0600) and the HMAC-signed
bundle next to it.

The DEFAULT policy is deliberately EMPTY -- every operation is DENIED
until KCC signs the real policy.  Provisioning a rule file:

    python .KCC/adapters/dsh/gate/sign-policy.py --out-dir GATE \
        --rules-file kcc-policy-rules.json

``--rules-file`` is a JSON array of exact-match rules:

    [
      {"operation": "exec", "resource": "pytest",
       "data_class": "PUBLIC", "decision": "ALLOWED"},
      {"operation": "write", "resource": "src/kcc.py",
       "data_class": "PUBLIC", "decision": "ALLOWED"}
    ]

Re-signing with ``--secret-file`` (an existing ``.gate-secret``) keeps the
same key so a redeployed bundle does not invalidate previously minted
audits.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from kcc_autobuild.policy import PolicyDecision, PolicyRule
from kcc_autobuild.dsh_gate import (
    DEFAULT_BUNDLE_NAME,
    DEFAULT_SECRET_NAME,
    provision_gate_policy,
)


def _parse_rules(rules_file: Path) -> list[PolicyRule]:
    data = json.loads(rules_file.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError("rules file must be a JSON array")
    rules: list[PolicyRule] = []
    for entry in data:
        if not isinstance(entry, dict):
            raise ValueError("each rule must be a JSON object")
        rules.append(
            PolicyRule(
                operation=entry["operation"],
                resource=entry["resource"],
                data_class=entry["data_class"],
                decision=PolicyDecision(entry["decision"]),
            )
        )
    return rules


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        type=Path,
        required=True,
        help="Gate directory the bundle + 0600 secret are written to",
    )
    parser.add_argument(
        "--rules-file",
        type=Path,
        default=None,
        help="JSON array of exact-match policy rules (default: empty = fail closed)",
    )
    parser.add_argument(
        "--secret-file",
        type=Path,
        default=None,
        help="Reuse an existing .gate-secret instead of generating a new key",
    )
    parser.add_argument(
        "--bundle-name", default=DEFAULT_BUNDLE_NAME, help="Bundle filename"
    )
    parser.add_argument(
        "--secret-name", default=DEFAULT_SECRET_NAME, help="Secret filename"
    )
    args = parser.parse_args(argv)

    rules = _parse_rules(args.rules_file) if args.rules_file is not None else []
    secret = None
    if args.secret_file is not None:
        secret = args.secret_file.read_text(encoding="utf-8").strip()
    bundle_path, secret_path = provision_gate_policy(
        args.out_dir,
        rules,
        secret=secret,
        bundle_name=args.bundle_name,
        secret_name=args.secret_name,
    )
    print(f"signed policy bundle: {bundle_path}")
    print(f"owner-only secret:    {secret_path} (mode 0600; values never printed)")
    print(f"rules in bundle:      {len(rules)} (empty = every operation denied)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 -- deterministic CLI failure
        print(f"error: cannot provision the gate policy: {exc}", file=sys.stderr)
        raise SystemExit(1)
