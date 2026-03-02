#!/usr/bin/env bash

set -euo pipefail

# Simple wrapper to run the Python mirror script.
# Forwards all CLI arguments.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/mirror.py" "$@"