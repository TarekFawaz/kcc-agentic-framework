#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 - Compatibility wrapper. Delegates to ../.KCC/tools/start-agent-session.sh.
# Passes through all flags including --Sandbox / -Sandbox.
# Prefer .KCC/tools/start-agent-session.sh in new docs and examples.
# If this file is not executable after clone, run: chmod +x tools/start-agent-session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../.KCC/tools/start-agent-session.sh"
if [ ! -f "$TARGET" ]; then
  echo "error: canonical tool not found: $TARGET" >&2
  exit 1
fi
exec bash "$TARGET" "$@"
