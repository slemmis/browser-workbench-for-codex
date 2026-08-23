#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MCP_VERSION="0.0.79"
MCP_PACKAGE="@playwright/mcp@${MCP_VERSION}"

die() {
  printf 'browser-workbench setup: %s\n' "$*" >&2
  exit 1
}

resolve_path() {
  local candidate="$1"
  if [[ "$candidate" == /* ]]; then
    printf '%s\n' "$candidate"
  else
    printf '%s/%s\n' "$PLUGIN_DIR" "$candidate"
  fi
}

HOME_DIR="${HOME:-}"
[[ -n "$HOME_DIR" ]] || die "HOME is required to locate the browser-workbench cache"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME_DIR/.cache}"
CACHE_ROOT="$(resolve_path "$CACHE_HOME")/browser-workbench"

NODE="$(command -v node 2>/dev/null || true)"
[[ -n "$NODE" ]] || die "Node.js 20 or newer is required"
NODE_VERSION="$("$NODE" -p 'process.versions.node')"
NODE_MAJOR="${NODE_VERSION%%.*}"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ && "$NODE_MAJOR" -ge 20 ]] || die "Node.js 20 or newer is required (found $NODE_VERSION)"

for tool in npm npx; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required and was not found on PATH"
done

RUNTIME_DIR="$(resolve_path "${BROWSER_WORKBENCH_RUNTIME_DIR:-$CACHE_ROOT/runtime}")"
BROWSERS_PATH="$(resolve_path "${BROWSER_WORKBENCH_BROWSERS_PATH:-$CACHE_ROOT/browsers}")"
mkdir -p "$RUNTIME_DIR" "$BROWSERS_PATH"

printf 'Installing %s into the local runtime...\n' "$MCP_PACKAGE"
if ! npm install --prefix "$RUNTIME_DIR" --no-audit --no-fund --ignore-scripts --save-exact "$MCP_PACKAGE"; then
  die "npm could not prepare the pinned MCP package; check network access and npm permissions"
fi

MCP_PACKAGE_JSON="$RUNTIME_DIR/node_modules/@playwright/mcp/package.json"
PLAYWRIGHT_PACKAGE_JSON="$RUNTIME_DIR/node_modules/playwright/package.json"
[[ -f "$MCP_PACKAGE_JSON" ]] || die "installed @playwright/mcp package metadata is missing"
[[ -f "$PLAYWRIGHT_PACKAGE_JSON" ]] || die "installed Playwright package metadata is missing"

INSTALLED_MCP_VERSION="$("$NODE" -e 'const fs = require("node:fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.version || "");' "$MCP_PACKAGE_JSON")"
[[ "$INSTALLED_MCP_VERSION" == "$MCP_VERSION" ]] || die "expected @playwright/mcp@$MCP_VERSION but found @$INSTALLED_MCP_VERSION"

# Resolve the browser installer from @playwright/mcp metadata, not a separately guessed version.
PLAYWRIGHT_VERSION="$("$NODE" -e 'const fs = require("node:fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write((p.dependencies && p.dependencies.playwright) || "");' "$MCP_PACKAGE_JSON")"
INSTALLED_PLAYWRIGHT_VERSION="$("$NODE" -e 'const fs = require("node:fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.version || "");' "$PLAYWRIGHT_PACKAGE_JSON")"
[[ -n "$PLAYWRIGHT_VERSION" ]] || die "@playwright/mcp metadata does not declare a Playwright dependency"
[[ "$INSTALLED_PLAYWRIGHT_VERSION" == "$PLAYWRIGHT_VERSION" ]] || die "Playwright metadata mismatch: MCP declares $PLAYWRIGHT_VERSION but installed $INSTALLED_PLAYWRIGHT_VERSION"

printf 'Installing Chromium with Playwright %s into the local browser cache...\n' "$PLAYWRIGHT_VERSION"
export PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_PATH"
PLAYWRIGHT_CLI="$RUNTIME_DIR/node_modules/playwright/cli.js"
  if ! "$NODE" "$PLAYWRIGHT_CLI" install chromium; then
  printf '%s\n' \
    'Chromium installation failed.' \
    'No sudo was invoked and no Linux system packages were changed.' \
    'On Linux/WSL, install your distribution''s Playwright browser dependencies deliberately, then rerun setup.sh.' >&2
  exit 1
fi

printf 'Browser Workbench for Codex setup complete. Run scripts/doctor.sh, scripts/smoke-test.sh, and scripts/mcp-smoke-test.sh.\n'
