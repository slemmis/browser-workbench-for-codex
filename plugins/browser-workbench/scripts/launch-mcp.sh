#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MCP_VERSION="0.0.79"

die() {
  printf 'browser-workbench: %s\n' "$*" >&2
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
MCP_TMP_DIR="$(resolve_path "${BROWSER_WORKBENCH_TMPDIR:-$CACHE_ROOT/tmp}")"
MCP_OUTPUT_DIR="$(resolve_path "${BROWSER_WORKBENCH_OUTPUT_DIR:-$CACHE_ROOT/output}")"
export TMPDIR="$MCP_TMP_DIR" TEMP="$MCP_TMP_DIR" TMP="$MCP_TMP_DIR"

sanitize_mcp_environment() {
  local env_name
  while IFS= read -r env_name; do
    case "$env_name" in
      PLAYWRIGHT_MCP_*) unset "$env_name" ;;
    esac
  done < <(compgen -e)
}

sanitize_mcp_environment

MODE="${BROWSER_WORKBENCH_MODE:-isolated}"
case "$MODE" in
  isolated|persistent|extension|cdp) ;;
  *) die "BROWSER_WORKBENCH_MODE must be isolated, persistent, extension, or cdp (got '$MODE')" ;;
esac

HEADED="${BROWSER_WORKBENCH_HEADED:-0}"
case "$HEADED" in
  1|true) HEADED=1 ;;
  0|false|'') HEADED=0 ;;
  *) die "BROWSER_WORKBENCH_HEADED must be 0, 1, false, or true" ;;
esac

BROWSER="${BROWSER_WORKBENCH_BROWSER:-}"
if [[ -n "$BROWSER" ]]; then
  case "$BROWSER" in
    chrome|firefox|webkit|msedge) ;;
    *) die "BROWSER_WORKBENCH_BROWSER must be chrome, firefox, webkit, or msedge" ;;
  esac
fi

CAPS="${BROWSER_WORKBENCH_CAPS:-}"
if [[ -n "$CAPS" ]]; then
  [[ "$CAPS" != *[[:space:]]* ]] || die "BROWSER_WORKBENCH_CAPS must not contain whitespace"
  [[ "$CAPS" != ,* && "$CAPS" != *, && "$CAPS" != *,,* ]] || die "BROWSER_WORKBENCH_CAPS contains an empty capability"
  IFS=',' read -r -a CAP_LIST <<< "$CAPS"
  declare -A SEEN_CAPS=()
  for cap in "${CAP_LIST[@]}"; do
    case "$cap" in
      vision|pdf|devtools) ;;
      *) die "BROWSER_WORKBENCH_CAPS supports only vision, pdf, and devtools" ;;
    esac
    [[ -z "${SEEN_CAPS[$cap]+x}" ]] || die "BROWSER_WORKBENCH_CAPS contains duplicate '$cap'"
    SEEN_CAPS["$cap"]=1
  done
fi

CDP_ENDPOINT="${BROWSER_WORKBENCH_CDP_ENDPOINT:-}"
if [[ "$MODE" == cdp ]]; then
  [[ -n "$CDP_ENDPOINT" ]] || die "BROWSER_WORKBENCH_CDP_ENDPOINT is required for cdp mode"
fi

if [[ "$MODE" == extension && -n "$BROWSER" ]]; then
  case "$BROWSER" in
    chrome|msedge) ;;
    *) die "extension mode supports only chrome or msedge" ;;
  esac
fi

USER_DATA_DIR="${BROWSER_WORKBENCH_USER_DATA_DIR:-}"
if [[ -n "$USER_DATA_DIR" && "$MODE" != persistent ]]; then
  die "BROWSER_WORKBENCH_USER_DATA_DIR is only valid in persistent mode"
fi
if [[ "$MODE" == persistent && -z "$USER_DATA_DIR" ]]; then
  USER_DATA_DIR="$CACHE_ROOT/profiles/default"
fi
if [[ -n "$USER_DATA_DIR" ]]; then
  USER_DATA_DIR="$(resolve_path "$USER_DATA_DIR")"
fi

DRY_RUN="${BROWSER_WORKBENCH_DRY_RUN:-0}"
case "$DRY_RUN" in
  0|'') DRY_RUN=0 ;;
  1) DRY_RUN=1 ;;
  *) die "BROWSER_WORKBENCH_DRY_RUN must be 0 or 1" ;;
esac

if [[ "$DRY_RUN" == 0 ]]; then
  mkdir -p "$MCP_TMP_DIR" "$MCP_OUTPUT_DIR"
fi

NODE="$(command -v node 2>/dev/null || true)"
[[ -n "$NODE" ]] || die "Node.js is required; run scripts/setup.sh first"
NODE_VERSION="$("$NODE" -p 'process.versions.node')"
NODE_MAJOR="${NODE_VERSION%%.*}"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ && "$NODE_MAJOR" -ge 20 ]] || die "Node.js 20 or newer is required (found $NODE_VERSION)"

if [[ "$MODE" == cdp ]]; then
  [[ "$CDP_ENDPOINT" != *[[:space:]]* ]] || die "BROWSER_WORKBENCH_CDP_ENDPOINT must not contain whitespace"
  if ! "$NODE" -e '
    const value = process.argv[1];
    let parsed;
    try { parsed = new URL(value); } catch { process.exit(1); }
    const validProtocol = ["http:", "https:", "ws:", "wss:"].includes(parsed.protocol);
    const safeHost = parsed.hostname && parsed.hostname !== "0.0.0.0";
    if (!validProtocol || !safeHost || parsed.username || parsed.password) process.exit(1);
  ' "$CDP_ENDPOINT"; then
    die "BROWSER_WORKBENCH_CDP_ENDPOINT must be a credential-free http(s):// or ws(s):// endpoint and must not target 0.0.0.0"
  fi
fi

RUNTIME_DIR="$(resolve_path "${BROWSER_WORKBENCH_RUNTIME_DIR:-$CACHE_ROOT/runtime}")"
MCP_CLI="$RUNTIME_DIR/node_modules/@playwright/mcp/cli.js"
BROWSERS_PATH="$(resolve_path "${BROWSER_WORKBENCH_BROWSERS_PATH:-$CACHE_ROOT/browsers}")"
export PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_PATH"

MCP_ARGS=()
MCP_ARGS=(--output-dir "$MCP_OUTPUT_DIR")
case "$MODE" in
  isolated) MCP_ARGS+=(--isolated) ;;
  persistent) ;;
  extension) MCP_ARGS+=(--extension) ;;
  cdp) MCP_ARGS+=(--cdp-endpoint "$CDP_ENDPOINT") ;;
esac

if [[ "$MODE" == isolated || "$MODE" == persistent ]]; then
  [[ "$HEADED" == 1 ]] || MCP_ARGS+=(--headless)
fi

CHROMIUM_EXECUTABLE=""
if [[ -z "$BROWSER" && ( "$MODE" == isolated || "$MODE" == persistent ) ]]; then
  if [[ -f "$MCP_CLI" ]]; then
    PLAYWRIGHT_PACKAGE="$RUNTIME_DIR/node_modules/playwright"
    [[ -d "$PLAYWRIGHT_PACKAGE" ]] || die "Pinned Playwright package is not prepared at $RUNTIME_DIR; run scripts/setup.sh"
    CHROMIUM_EXECUTABLE="$("$NODE" -e 'const { chromium } = require(process.argv[1]); process.stdout.write(chromium.executablePath());' "$PLAYWRIGHT_PACKAGE" 2>/dev/null)" || die "Unable to resolve Chromium from the pinned Playwright API"
    [[ -n "$CHROMIUM_EXECUTABLE" && -x "$CHROMIUM_EXECUTABLE" ]] || die "Resolved Chromium executable is missing or not executable: $CHROMIUM_EXECUTABLE"
  elif [[ "$DRY_RUN" == 0 ]]; then
    die "Pinned @playwright/mcp@$MCP_VERSION is not prepared at $RUNTIME_DIR; run scripts/setup.sh"
  fi
fi
[[ -n "$CHROMIUM_EXECUTABLE" ]] && MCP_ARGS+=(--executable-path "$CHROMIUM_EXECUTABLE")
[[ -n "$BROWSER" ]] && MCP_ARGS+=(--browser "$BROWSER")
[[ -n "$CAPS" ]] && MCP_ARGS+=(--caps "$CAPS")
[[ -n "$USER_DATA_DIR" ]] && MCP_ARGS+=(--user-data-dir "$USER_DATA_DIR")

if [[ "$DRY_RUN" == 1 ]]; then
  printf 'browser-workbench dry run: mode=%s headed=%s browser=%s caps=%s\n' "$MODE" "$HEADED" "${BROWSER:-default}" "${CAPS:-none}"
  printf 'would exec: %q %q' "$NODE" "$MCP_CLI"
  printf ' %q' "${MCP_ARGS[@]}"
  printf '\n'
  exit 0
fi

[[ -f "$MCP_CLI" ]] || die "Pinned @playwright/mcp@$MCP_VERSION is not prepared at $RUNTIME_DIR; run scripts/setup.sh"

# Keep stdout untouched: it is the MCP JSON-RPC stream. Diagnostics go to stderr.
exec "$NODE" "$MCP_CLI" "${MCP_ARGS[@]}"
