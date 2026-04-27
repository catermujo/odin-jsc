#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# DUMBAI: JSC currently ships shared artifacts only; keep build_static as a naming-compatible alias.
exec "$ROOT/build.sh" "$@"
