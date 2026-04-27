#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_BIN="${PYTHON:-python3}"

# DUMBAI: keep a vendor-root Unix build entrypoint so JSC follows the same script surface as other vendor deps.
exec "$PYTHON_BIN" "$ROOT/scripts/build_cjsc.py" "$@"
