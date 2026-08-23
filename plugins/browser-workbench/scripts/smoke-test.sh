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
[[ -n "$HOME_DIR" ]] || { printf 'browser-workbench smoke test: HOME is required to locate the browser-workbench cache\n' >&2; exit 1; }
CACHE_HOME="${XDG_CACHE_HOME:-$HOME_DIR/.cache}"
CACHE_ROOT="$(resolve_path "$CACHE_HOME")/browser-workbench"

NODE="$(command -v node 2>/dev/null || true)"
[[ -n "$NODE" ]] || { printf 'browser-workbench smoke test: Node.js is required; run scripts/setup.sh\n' >&2; exit 1; }
NODE_VERSION="$("$NODE" -p 'process.versions.node')"
NODE_MAJOR="${NODE_VERSION%%.*}"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ && "$NODE_MAJOR" -ge 20 ]] || { printf 'browser-workbench smoke test: Node.js 20 or newer is required (found %s)\n' "$NODE_VERSION" >&2; exit 1; }
RUNTIME_DIR="$(resolve_path "${BROWSER_WORKBENCH_RUNTIME_DIR:-$CACHE_ROOT/runtime}")"
BROWSERS_PATH="$(resolve_path "${BROWSER_WORKBENCH_BROWSERS_PATH:-$CACHE_ROOT/browsers}")"
PLAYWRIGHT_PACKAGE="$RUNTIME_DIR/node_modules/playwright"
[[ -d "$PLAYWRIGHT_PACKAGE" ]] || { printf 'browser-workbench smoke test: run scripts/setup.sh first\n' >&2; exit 1; }
OUTPUT_PATH="$(resolve_path "${BROWSER_WORKBENCH_SMOKE_OUTPUT:-$CACHE_ROOT/runtime/smoke/rendered.png}")"
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
export PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_PATH"

if ! "$NODE" - "$PLAYWRIGHT_PACKAGE" "$OUTPUT_PATH" <<'NODE'
const playwrightPackage = process.argv[2];
const outputPath = process.argv[3];
const { chromium } = require(playwrightPackage);

(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.goto('data:text/html,<main><h1 id="title">Browser Workbench for Codex smoke</h1><p id="status">Rendered content OK</p></main>');
    const title = await page.locator('#title').textContent();
    const status = await page.locator('#status').textContent();
    if (title !== 'Browser Workbench for Codex smoke' || status !== 'Rendered content OK') {
      throw new Error(`unexpected rendered content: ${title} / ${status}`);
    }
    await page.screenshot({ path: outputPath });
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(`browser-workbench smoke test failed: ${error.message}`);
  process.exitCode = 1;
});
NODE
then
  printf '%s\n' \
    'The browser could not launch.' \
    'On Linux/WSL this usually means system browser libraries are missing; install them deliberately for your distribution and rerun smoke-test.sh.' >&2
  exit 1
fi

[[ -s "$OUTPUT_PATH" ]] || { printf 'browser-workbench smoke test: screenshot was not created\n' >&2; exit 1; }
printf 'Browser smoke test passed: rendered content verified; screenshot written to %s\n' "$OUTPUT_PATH"
