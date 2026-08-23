#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHON="$(command -v python3 2>/dev/null || true)"
[[ -n "$PYTHON" ]] || { printf 'browser-workbench MCP smoke test: python3 is required\n' >&2; exit 1; }

exec "$PYTHON" "$SCRIPT_DIR/mcp_smoke_test.py"
