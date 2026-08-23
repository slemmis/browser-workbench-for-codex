#!/usr/bin/env bash
set -euo pipefail
umask 077

BW_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BW_PLUGIN_DIR="$(cd -- "$BW_SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=runtime/common.sh
source "$BW_SCRIPT_DIR/runtime/common.sh"

die() { printf 'browser-workbench smoke test: %s\n' "$*" >&2; exit 1; }
bw_init_paths || die "${BW_PATH_ERROR:-unable to resolve browser-workbench paths}"
bw_sanitize_node_environment
bw_find_node || die "Node.js 20 or newer is required"
bw_validate_runtime || die "exact pinned runtime is not ready; run scripts/setup.sh"
bw_chromium_ready || die "pinned Chromium is not ready; run scripts/setup.sh"

if [[ -n "${BROWSER_WORKBENCH_SMOKE_OUTPUT:-}" ]]; then
  OUTPUT_PATH="$(bw_resolve_override_path "$BROWSER_WORKBENCH_SMOKE_OUTPUT")"
  mkdir -p -- "$(dirname -- "$OUTPUT_PATH")"
  OWNED_OUTPUT=0
elif [[ "$BW_OUTPUT_CUSTOM" == 1 ]]; then
  mkdir -p -- "$BW_OUTPUT_DIR/smoke"
  OUTPUT_PATH="$BW_OUTPUT_DIR/smoke/rendered.png"
  OWNED_OUTPUT=0
else
  bw_secure_owned_dir "$BW_CACHE_ROOT" || die "cache root is unsafe"
  bw_secure_owned_dir "$BW_OUTPUT_DIR" || die "output directory is unsafe"
  bw_secure_owned_dir "$BW_OUTPUT_DIR/smoke" || die "smoke output directory is unsafe"
  OUTPUT_PATH="$BW_OUTPUT_DIR/smoke/rendered.png"
  OWNED_OUTPUT=1
fi
export PLAYWRIGHT_BROWSERS_PATH="$BW_BROWSERS_PATH"

if ! "$BW_NODE" - "$BW_PLAYWRIGHT_PACKAGE" "$OUTPUT_PATH" <<'NODE'
const playwrightPackage = process.argv[2];
const outputPath = process.argv[3];
const { chromium } = require(playwrightPackage);
(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`<!doctype html>
      <style>
        html, body { margin: 0; background: white; }
        #pixel-marker { position: fixed; inset: 0 auto auto 0; width: 16px; height: 16px; background: rgb(255, 0, 255); }
        main { margin: 24px; }
      </style>
      <div id="pixel-marker" aria-hidden="true"></div>
      <main><h1 id="title">Browser Workbench for Codex smoke</h1><p id="status">Rendered content OK</p></main>`);
    const title = await page.locator('#title').textContent();
    const status = await page.locator('#status').textContent();
    if (title !== 'Browser Workbench for Codex smoke' || status !== 'Rendered content OK') throw new Error(`unexpected rendered content: ${title} / ${status}`);
    await page.screenshot({ path: outputPath });
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(`browser-workbench smoke test failed: ${error.message}`); process.exitCode = 1; });
NODE
then
  printf '%s\n' 'The browser could not launch.' 'On Linux/WSL, install required browser libraries deliberately and rerun the smoke test.' >&2
  exit 1
fi

[[ -s "$OUTPUT_PATH" ]] || die "screenshot was not created"
VALIDATOR="$BW_SCRIPT_DIR/validate-png.mjs"
[[ -f "$VALIDATOR" ]] || die "bundled PNG validator is missing"
"$BW_NODE" "$VALIDATOR" --assert-pixel 4,4,255,0,255,255 "$OUTPUT_PATH" >/dev/null || die "screenshot failed structural validation or deterministic pixel assertion"
[[ "$OWNED_OUTPUT" == 0 ]] || chmod 0600 -- "$OUTPUT_PATH"
printf 'Browser smoke test passed: rendered content and screenshot structure verified; screenshot written to %s\n' "$OUTPUT_PATH"
