#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

resolve_path() {
  local candidate="$1"
  if [[ "$candidate" == /* ]]; then
    printf '%s\n' "$candidate"
  else
    printf '%s/%s\n' "$PLUGIN_DIR" "$candidate"
  fi
}

HOME_DIR="${HOME:-}"
if [[ -z "$HOME_DIR" ]]; then
  printf 'Cache: HOME is not set\n'
  CACHE_ROOT=""
else
  CACHE_HOME="${XDG_CACHE_HOME:-$HOME_DIR/.cache}"
  CACHE_ROOT="$(resolve_path "$CACHE_HOME")/browser-workbench"
fi

printf 'Browser Workbench for Codex doctor (read-only)\n'
if [[ "$(uname -s 2>/dev/null || true)" == Linux ]]; then
  printf 'OS: Linux\n'
else
  printf 'OS: %s (Linux/WSL is the supported target)\n' "$(uname -s 2>/dev/null || printf unknown)"
fi
if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version; then
  printf 'WSL: yes\n'
else
  printf 'WSL: no\n'
fi

NODE="$(command -v node 2>/dev/null || true)"
if [[ -n "$NODE" ]]; then
  printf 'Node: %s (%s)\n' "$NODE" "$("$NODE" -p 'process.versions.node')"
else
  printf 'Node: missing\n'
fi
for tool in npm npx; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s: available\n' "$tool"
  else
    printf '%s: missing\n' "$tool"
  fi
done

if [[ -n "${DISPLAY:-}" ]]; then printf 'Display: DISPLAY configured\n'; else printf 'Display: DISPLAY not configured\n'; fi
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then printf 'WSLg: Wayland configured\n'; elif [[ -d /mnt/wslg ]]; then printf 'WSLg: runtime directory detected\n'; else printf 'WSLg: not detected\n'; fi

if [[ -n "${BROWSER_WORKBENCH_RUNTIME_DIR:-}" ]]; then
  RUNTIME_DIR="$(resolve_path "$BROWSER_WORKBENCH_RUNTIME_DIR")"
elif [[ -n "$CACHE_ROOT" ]]; then
  RUNTIME_DIR="$CACHE_ROOT/runtime"
else
  RUNTIME_DIR=""
fi
if [[ -n "${BROWSER_WORKBENCH_BROWSERS_PATH:-}" ]]; then
  BROWSERS_PATH="$(resolve_path "$BROWSER_WORKBENCH_BROWSERS_PATH")"
elif [[ -n "$CACHE_ROOT" ]]; then
  BROWSERS_PATH="$CACHE_ROOT/browsers"
else
  BROWSERS_PATH=""
fi
MCP_PACKAGE_JSON="${RUNTIME_DIR:+$RUNTIME_DIR/node_modules/@playwright/mcp/package.json}"
PLAYWRIGHT_PACKAGE_JSON="${RUNTIME_DIR:+$RUNTIME_DIR/node_modules/playwright/package.json}"
if [[ -n "$NODE" && -f "$MCP_PACKAGE_JSON" ]]; then
  MCP_VERSION="$("$NODE" -e 'const fs = require("node:fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.version || "unknown");' "$MCP_PACKAGE_JSON")"
  DECLARED_PLAYWRIGHT="$("$NODE" -e 'const fs = require("node:fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write((p.dependencies && p.dependencies.playwright) || "unknown");' "$MCP_PACKAGE_JSON")"
  printf 'MCP package: ready (@playwright/mcp %s; Playwright declaration %s)\n' "$MCP_VERSION" "$DECLARED_PLAYWRIGHT"
else
  printf 'MCP package: not prepared\n'
fi
if [[ -n "$NODE" && -f "$PLAYWRIGHT_PACKAGE_JSON" ]]; then
  PLAYWRIGHT_INSTALLED="$("$NODE" -e 'const fs = require("node:fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.version || "unknown");' "$PLAYWRIGHT_PACKAGE_JSON")"
  printf 'Playwright package: ready (%s)\n' "$PLAYWRIGHT_INSTALLED"
else
  printf 'Playwright package: not prepared\n'
fi
if [[ -n "$NODE" && -n "$RUNTIME_DIR" && -d "$RUNTIME_DIR/node_modules/playwright" ]]; then
  export PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_PATH"
  if CHROMIUM_EXECUTABLE="$("$NODE" -e 'const { chromium } = require(process.argv[1]); process.stdout.write(chromium.executablePath());' "$RUNTIME_DIR/node_modules/playwright" 2>/dev/null)" && [[ -x "$CHROMIUM_EXECUTABLE" ]]; then
    printf 'Chromium executable: ready\n'
  else
    printf 'Chromium executable: not ready\n'
  fi
else
  printf 'Chromium executable: not ready\n'
fi
if [[ -n "$BROWSERS_PATH" && -d "$BROWSERS_PATH" ]] && find "$BROWSERS_PATH" -mindepth 1 -maxdepth 2 -type d \( -name 'chromium-*' -o -name 'chromium_headless_shell-*' \) -print -quit 2>/dev/null | grep -q .; then
  printf 'Chromium browser: cache present\n'
else
  printf 'Chromium browser: cache not detected\n'
fi

MODE="${BROWSER_WORKBENCH_MODE:-isolated}"
case "$MODE" in isolated|persistent|extension|cdp) printf 'Mode: %s (valid)\n' "$MODE" ;; *) printf 'Mode: %s (invalid)\n' "$MODE" ;; esac
HEADED="${BROWSER_WORKBENCH_HEADED:-0}"
case "$HEADED" in 1|true) printf 'Headed: enabled\n' ;; 0|false|'') printf 'Headed: disabled (headless default)\n' ;; *) printf 'Headed: invalid value\n' ;; esac
printf 'Browser selection: %s\n' "${BROWSER_WORKBENCH_BROWSER:-MCP default}"
printf 'Capabilities: %s\n' "${BROWSER_WORKBENCH_CAPS:-none}"
if [[ -n "${BROWSER_WORKBENCH_USER_DATA_DIR:-}" ]]; then printf 'Persistent profile: configured (path hidden)\n'; else printf 'Persistent profile: MCP default\n'; fi
if [[ -n "${BROWSER_WORKBENCH_CDP_ENDPOINT:-}" ]]; then printf 'CDP endpoint: configured (value hidden)\n'; else printf 'CDP endpoint: not configured\n'; fi
