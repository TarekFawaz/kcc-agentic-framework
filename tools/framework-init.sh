#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 - Compatibility wrapper. Delegates to ../.KCC/tools/framework-init.sh.
# Prefer .KCC/tools/framework-init.sh in new docs and examples.
# If this file is not executable after clone, run: chmod +x tools/framework-init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../.KCC/tools/framework-init.sh"
if [ ! -f "$TARGET" ]; then
  echo "error: canonical tool not found: $TARGET" >&2
  exit 1
fi
exec bash "$TARGET" "$@"
