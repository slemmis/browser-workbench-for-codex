#!/usr/bin/env bash
set -euo pipefail
umask 077

BW_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BW_PLUGIN_DIR="$(cd -- "$BW_SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=runtime/common.sh
source "$BW_SCRIPT_DIR/runtime/common.sh"

die() {
  printf 'browser-workbench setup: %s\n' "$*" >&2
  exit 1
}

bw_init_paths || die "${BW_PATH_ERROR:-unable to resolve browser-workbench paths}"
bw_sanitize_node_environment
bw_find_node || die "Node.js 20 or newer is required"
command -v npm >/dev/null 2>&1 || die "npm is required and was not found on PATH"
command -v flock >/dev/null 2>&1 || die "flock is required for concurrency-safe setup"

source_manifest_version="$(bw_read_package_field "$BW_SCRIPT_DIR/runtime/package.json" 'data.dependencies && data.dependencies["@playwright/mcp"]')" || true
source_lock_version="$(bw_read_package_field "$BW_SCRIPT_DIR/runtime/package-lock.json" 'data.packages && data.packages["node_modules/@playwright/mcp"] && data.packages["node_modules/@playwright/mcp"].version')" || true
source_lock_playwright="$(bw_read_package_field "$BW_SCRIPT_DIR/runtime/package-lock.json" 'data.packages && data.packages["node_modules/playwright"] && data.packages["node_modules/playwright"].version')" || true
source_lock_playwright_core="$(bw_read_package_field "$BW_SCRIPT_DIR/runtime/package-lock.json" 'data.packages && data.packages["node_modules/playwright-core"] && data.packages["node_modules/playwright-core"].version')" || true
[[ "$source_manifest_version" == "$BW_MCP_VERSION" && "$source_lock_version" == "$BW_MCP_VERSION" ]] || die "committed manifest/lock does not match runtime MCP pin $BW_MCP_VERSION"
[[ "$source_lock_playwright" == "$BW_PLAYWRIGHT_VERSION" && "$source_lock_playwright_core" == "$BW_PLAYWRIGHT_VERSION" ]] || die "committed lock does not match Playwright/Playwright Core pin $BW_PLAYWRIGHT_VERSION"

[[ ! -L "$BW_RUNTIME_DIR" ]] || die "runtime target must not be a symlink"
[[ ! -L "$BW_BROWSERS_ROOT" ]] || die "browser cache target must not be a symlink"
BW_RUNTIME_DIR="$(realpath -m -- "$BW_RUNTIME_DIR")" || die "cannot normalize runtime target"
BW_BROWSERS_ROOT="$(realpath -m -- "$BW_BROWSERS_ROOT")" || die "cannot normalize browser cache target"
bw_set_runtime_derived_paths || true
bw_set_browser_active_path || true
[[ "$BW_RUNTIME_DIR" != / && "$BW_BROWSERS_ROOT" != / ]] || die "runtime and browser cache targets must not be the filesystem root"
[[ "$BW_RUNTIME_DIR" != "$BW_BROWSERS_ROOT" ]] || die "runtime and browser cache targets must be different"
case "$BW_RUNTIME_DIR/" in "$BW_BROWSERS_ROOT/"*) die "runtime target must not be inside the browser cache target" ;; esac
case "$BW_BROWSERS_ROOT/" in "$BW_RUNTIME_DIR/"*) die "browser cache target must not be inside the runtime target" ;; esac
for protected_path in / "$BW_HOME_DIR" "$BW_CACHE_HOME" "$BW_CACHE_ROOT" "$BW_PLUGIN_DIR" "$BW_SCRIPT_DIR"; do
  protected_path="$(realpath -m -- "$protected_path")"
  case "$protected_path/" in
    "$BW_RUNTIME_DIR/"*) die "runtime target is too broad and would contain a protected root" ;;
  esac
  case "$protected_path/" in
    "$BW_BROWSERS_ROOT/"*) die "browser cache target is too broad and would contain a protected root" ;;
  esac
done

# The cache root and lock are always workbench-owned, even when runtime/browser
# locations are explicitly overridden. Custom paths themselves are not chmodded.
bw_secure_owned_dir "$BW_CACHE_ROOT" || die "cache root is a symlink, non-directory, unowned, or unusable"
[[ ! -L "$BW_LOCK_FILE" ]] || die "setup lock must not be a symlink"
exec {BW_LOCK_FD}>"$BW_LOCK_FILE" || die "cannot create setup lock"
chmod 0600 -- "$BW_LOCK_FILE" || die "cannot secure setup lock"
flock "$BW_LOCK_FD" || die "cannot acquire setup lock"

if [[ "$BW_RUNTIME_CUSTOM" == 0 ]]; then bw_secure_owned_dir "$BW_RUNTIME_DIR" || die "runtime directory is unsafe"; fi
if [[ "$BW_BROWSERS_CUSTOM" == 0 ]]; then bw_secure_owned_dir "$BW_BROWSERS_ROOT" || die "browser cache directory is unsafe"; fi
[[ ! -e "$BW_RUNTIME_DIR/current" || -L "$BW_RUNTIME_DIR/current" ]] || die "runtime current pointer must be a symlink"
if [[ "$BW_BROWSERS_CUSTOM" == 0 ]]; then [[ ! -e "$BW_BROWSERS_ROOT/current" || -L "$BW_BROWSERS_ROOT/current" ]] || die "browser current pointer must be a symlink"; fi
if bw_validate_runtime && bw_chromium_ready; then
  if [[ "${BROWSER_WORKBENCH_SETUP_QUIET_READY:-0}" != 1 ]]; then
    printf 'Browser Workbench runtime is already ready (@playwright/mcp %s, Playwright %s).\n' "$BW_MCP_VERSION" "$BW_PLAYWRIGHT_VERSION"
  fi
  exit 0
fi

# A pre-generation owned cache is accepted only inside setup while holding the
# publication lock. It is copied into immutable generations; flat legacy files
# remain untouched for already-running clients.
BW_ALLOW_LEGACY_LAYOUT=1
bw_set_runtime_derived_paths || die "runtime pointer is unsafe: $BW_RUNTIME_POINTER_ERROR"
bw_set_browser_active_path || die "browser pointer is unsafe: $BW_BROWSER_POINTER_ERROR"
SOURCE_RUNTIME_READY=0
SOURCE_BROWSER_READY=0
if bw_validate_runtime; then SOURCE_RUNTIME_READY=1; fi
if [[ "$SOURCE_RUNTIME_READY" == 1 ]] && bw_chromium_ready; then SOURCE_BROWSER_READY=1; fi
unset BW_ALLOW_LEGACY_LAYOUT
MIGRATE_LEGACY_RUNTIME=0
MIGRATE_LEGACY_BROWSER=0
if [[ "$BW_RUNTIME_CUSTOM" == 0 && ! -L "$BW_RUNTIME_DIR/current" && "$SOURCE_RUNTIME_READY" == 1 ]]; then MIGRATE_LEGACY_RUNTIME=1; fi
if [[ "$BW_BROWSERS_CUSTOM" == 0 && ! -L "$BW_BROWSERS_ROOT/current" && "$SOURCE_BROWSER_READY" == 1 ]]; then MIGRATE_LEGACY_BROWSER=1; fi

runtime_parent="$(dirname -- "$BW_RUNTIME_DIR")"
browsers_parent="$(dirname -- "$BW_BROWSERS_ROOT")"
mkdir -p -- "$runtime_parent" "$browsers_parent"
if [[ "$BW_RUNTIME_CUSTOM" == 0 ]]; then bw_secure_owned_dir "$runtime_parent" || die "runtime parent is unsafe"; fi
if [[ "$BW_BROWSERS_CUSTOM" == 0 ]]; then bw_secure_owned_dir "$browsers_parent" || die "browser parent is unsafe"; fi

STAGE_RUNTIME="$(mktemp -d "$runtime_parent/.browser-workbench-runtime.stage.XXXXXX")" || die "cannot create runtime staging directory"
STAGE_BROWSERS=""
RUNTIME_GENERATION=""
RUNTIME_POINTER_TMP_DIR=""
RUNTIME_HAD_POINTER=0
RUNTIME_PREVIOUS_TARGET=""
RUNTIME_POINTER_SWAP_STARTED=0
BROWSER_GENERATION=""
BROWSER_POINTER_TMP_DIR=""
BROWSER_HAD_POINTER=0
BROWSER_PREVIOUS_TARGET=""
BROWSER_POINTER_SWAP_STARTED=0
SETUP_SUCCESS=0
cleanup() {
  local original_status=$? runtime_rollback_tmp="" browser_rollback_tmp=""
  set +e
  trap - HUP INT TERM
  if [[ "$SETUP_SUCCESS" == 0 && "$RUNTIME_POINTER_SWAP_STARTED" == 1 ]]; then
    if [[ "$RUNTIME_HAD_POINTER" == 1 ]]; then
      runtime_rollback_tmp="$(mktemp -d "$BW_RUNTIME_DIR/.browser-workbench-pointer.rollback.XXXXXX")"
      if [[ -n "$runtime_rollback_tmp" ]] && ln -s -- "$RUNTIME_PREVIOUS_TARGET" "$runtime_rollback_tmp/current" && mv -Tf -- "$runtime_rollback_tmp/current" "$BW_RUNTIME_DIR/current"; then
        rmdir -- "$runtime_rollback_tmp"
        runtime_rollback_tmp=""
      else
        printf 'browser-workbench setup: rollback failed; prior runtime generation remains at %s\n' "$RUNTIME_PREVIOUS_TARGET" >&2
      fi
    elif [[ -L "$BW_RUNTIME_DIR/current" ]]; then
      rm -f -- "$BW_RUNTIME_DIR/current"
    fi
  fi
  if [[ "$SETUP_SUCCESS" == 0 && "$BROWSER_POINTER_SWAP_STARTED" == 1 ]]; then
    if [[ "$BROWSER_HAD_POINTER" == 1 ]]; then
      browser_rollback_tmp="$(mktemp -d "$BW_BROWSERS_ROOT/.browser-workbench-pointer.rollback.XXXXXX")"
      if [[ -n "$browser_rollback_tmp" ]] && ln -s -- "$BROWSER_PREVIOUS_TARGET" "$browser_rollback_tmp/current" && mv -Tf -- "$browser_rollback_tmp/current" "$BW_BROWSERS_ROOT/current"; then
        rmdir -- "$browser_rollback_tmp"
        browser_rollback_tmp=""
      else
        printf 'browser-workbench setup: browser rollback failed; prior generation remains at %s\n' "$BROWSER_PREVIOUS_TARGET" >&2
      fi
    elif [[ -L "$BW_BROWSERS_ROOT/current" ]]; then
      rm -f -- "$BW_BROWSERS_ROOT/current"
    fi
  fi
  [[ -z "$STAGE_RUNTIME" || ! -e "$STAGE_RUNTIME" ]] || rm -rf -- "$STAGE_RUNTIME"
  [[ -z "$STAGE_BROWSERS" || ! -e "$STAGE_BROWSERS" ]] || rm -rf -- "$STAGE_BROWSERS"
  [[ -z "$RUNTIME_POINTER_TMP_DIR" || ! -d "$RUNTIME_POINTER_TMP_DIR" ]] || rm -rf -- "$RUNTIME_POINTER_TMP_DIR"
  [[ -z "$BROWSER_POINTER_TMP_DIR" || ! -d "$BROWSER_POINTER_TMP_DIR" ]] || rm -rf -- "$BROWSER_POINTER_TMP_DIR"
  [[ -z "$runtime_rollback_tmp" || ! -d "$runtime_rollback_tmp" ]] || rm -rf -- "$runtime_rollback_tmp"
  [[ -z "$browser_rollback_tmp" || ! -d "$browser_rollback_tmp" ]] || rm -rf -- "$browser_rollback_tmp"
  if [[ "$SETUP_SUCCESS" == 0 && -n "$RUNTIME_GENERATION" && -d "$RUNTIME_GENERATION" ]]; then
    local active_generation=""
    active_generation="$(realpath -e -- "$BW_RUNTIME_DIR/current" 2>/dev/null || true)"
    [[ "$active_generation" == "$RUNTIME_GENERATION" ]] || rm -rf -- "$RUNTIME_GENERATION"
  fi
  if [[ "$SETUP_SUCCESS" == 0 && -n "$BROWSER_GENERATION" && -d "$BROWSER_GENERATION" ]]; then
    local active_browser_generation=""
    active_browser_generation="$(realpath -e -- "$BW_BROWSERS_ROOT/current" 2>/dev/null || true)"
    [[ "$active_browser_generation" == "$BROWSER_GENERATION" ]] || rm -rf -- "$BROWSER_GENERATION"
  fi
  return "$original_status"
}
handle_signal() {
  local status="$1"
  trap - HUP INT TERM
  exit "$status"
}
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

if [[ "$MIGRATE_LEGACY_RUNTIME" == 1 ]]; then
  printf 'Migrating the validated legacy runtime into an immutable generation...\n'
  cp -a -- "$BW_RUNTIME_ACTIVE_DIR/package.json" "$BW_RUNTIME_ACTIVE_DIR/package-lock.json" "$BW_RUNTIME_ACTIVE_DIR/node_modules" "$STAGE_RUNTIME/"
else
  cp -- "$BW_SCRIPT_DIR/runtime/package.json" "$BW_SCRIPT_DIR/runtime/package-lock.json" "$STAGE_RUNTIME/"
  printf 'Installing the locked runtime @playwright/mcp@%s into a staging directory...\n' "$BW_MCP_VERSION"
  if ! npm ci --prefix "$STAGE_RUNTIME" --no-audit --no-fund --ignore-scripts; then
    die "npm ci could not prepare the locked runtime; the live runtime was not changed"
  fi
fi
chmod 0600 -- "$STAGE_RUNTIME/package.json" "$STAGE_RUNTIME/package-lock.json"

stage_mcp_json="$STAGE_RUNTIME/node_modules/@playwright/mcp/package.json"
stage_playwright_json="$STAGE_RUNTIME/node_modules/playwright/package.json"
stage_playwright_core_json="$STAGE_RUNTIME/node_modules/playwright-core/package.json"
stage_cli="$STAGE_RUNTIME/node_modules/@playwright/mcp/cli.js"
[[ -f "$stage_mcp_json" && -f "$stage_playwright_json" && -f "$stage_playwright_core_json" && -f "$stage_cli" ]] || die "staged dependency graph is incomplete"
stage_mcp="$(bw_read_package_field "$stage_mcp_json" 'data.version')" || true
stage_declared="$(bw_read_package_field "$stage_mcp_json" 'data.dependencies && data.dependencies.playwright')" || true
stage_playwright="$(bw_read_package_field "$stage_playwright_json" 'data.version')" || true
stage_playwright_core="$(bw_read_package_field "$stage_playwright_core_json" 'data.version')" || true
[[ "$stage_mcp" == "$BW_MCP_VERSION" ]] || die "lock/install mismatch: expected MCP $BW_MCP_VERSION, found ${stage_mcp:-unknown}"
[[ "$stage_declared" == "$BW_PLAYWRIGHT_VERSION" && "$stage_playwright" == "$BW_PLAYWRIGHT_VERSION" && "$stage_playwright_core" == "$BW_PLAYWRIGHT_VERSION" ]] || die "lock/install mismatch for Playwright/Playwright Core (expected $BW_PLAYWRIGHT_VERSION)"
bw_validate_installed_graph "$STAGE_RUNTIME" || die "staged packages do not match the locked package graph"

stage_playwright_package="$STAGE_RUNTIME/node_modules/playwright"
existing_browser=""
if [[ "$MIGRATE_LEGACY_BROWSER" == 1 ]]; then
  STAGE_BROWSERS="$(mktemp -d "$browsers_parent/.browser-workbench-browsers.stage.XXXXXX")" || die "cannot create browser staging directory"
  printf 'Migrating the validated legacy browser cache into an immutable generation...\n'
  (
    shopt -s dotglob nullglob
    for legacy_entry in "$BW_BROWSERS_ROOT"/*; do
      case "$(basename -- "$legacy_entry")" in current|.generations|.browser-workbench-pointer.*) continue ;; esac
      cp -a -- "$legacy_entry" "$STAGE_BROWSERS/"
    done
  )
  export PLAYWRIGHT_BROWSERS_PATH="$STAGE_BROWSERS"
  staged_browser="$($BW_NODE -e 'const {chromium}=require(process.argv[1]);process.stdout.write(chromium.executablePath())' "$stage_playwright_package" 2>/dev/null || true)"
  [[ -n "$staged_browser" && -x "$staged_browser" ]] || die "migrated browser cache does not contain the pinned executable"
else
  if [[ "$BW_BROWSERS_CUSTOM" == 0 && ! -L "$BW_BROWSERS_ROOT/current" ]]; then
    BW_BROWSERS_PATH="$BW_BROWSERS_ROOT"
  else
    bw_set_browser_active_path || die "browser cache pointer is invalid: $BW_BROWSER_POINTER_ERROR"
  fi
  export PLAYWRIGHT_BROWSERS_PATH="$BW_BROWSERS_PATH"
  existing_browser="$($BW_NODE -e 'const {chromium}=require(process.argv[1]);process.stdout.write(chromium.executablePath())' "$stage_playwright_package" 2>/dev/null || true)"
fi
if [[ "$MIGRATE_LEGACY_BROWSER" == 0 && ( -z "$existing_browser" || ! -x "$existing_browser" ) ]]; then
  if [[ "$BW_BROWSERS_CUSTOM" == 1 ]]; then
    browser_install_path="$BW_BROWSERS_ROOT"
    printf 'Installing pinned Chromium into the configured browser cache...\n'
  else
    STAGE_BROWSERS="$(mktemp -d "$browsers_parent/.browser-workbench-browsers.stage.XXXXXX")" || die "cannot create browser staging directory"
    browser_install_path="$STAGE_BROWSERS"
    printf 'Installing pinned Chromium into a staging directory...\n'
  fi
  export PLAYWRIGHT_BROWSERS_PATH="$browser_install_path"
  if ! "$BW_NODE" "$stage_playwright_package/cli.js" install chromium; then
    printf '%s\n' 'Chromium installation failed; the live runtime was not changed.' 'A user-configured existing browser cache may retain upstream installer temporary files.' 'No sudo or system package installation was attempted.' >&2
    exit 1
  fi
  staged_browser="$($BW_NODE -e 'const {chromium}=require(process.argv[1]);process.stdout.write(chromium.executablePath())' "$stage_playwright_package" 2>/dev/null || true)"
  [[ -n "$staged_browser" && -x "$staged_browser" ]] || die "Chromium installer returned success but no executable is ready"

fi

if [[ -n "$STAGE_BROWSERS" && "$BW_BROWSERS_CUSTOM" == 0 ]]; then
  BROWSER_GENERATION_ROOT="$BW_BROWSERS_ROOT/.generations"
  [[ ! -L "$BROWSER_GENERATION_ROOT" ]] || die "browser generation root must not be a symlink"
  mkdir -p -- "$BROWSER_GENERATION_ROOT"
  chmod 0700 -- "$BROWSER_GENERATION_ROOT"
  BROWSER_GENERATION="$(mktemp -d "$BROWSER_GENERATION_ROOT/browser.XXXXXX")"
  rmdir -- "$BROWSER_GENERATION"
  mv -- "$STAGE_BROWSERS" "$BROWSER_GENERATION"
  STAGE_BROWSERS=""

  if [[ -L "$BW_BROWSERS_ROOT/current" ]]; then
    BROWSER_HAD_POINTER=1
    BROWSER_PREVIOUS_TARGET="$(readlink -- "$BW_BROWSERS_ROOT/current")"
  elif [[ -e "$BW_BROWSERS_ROOT/current" ]]; then
    die "browser current pointer must be a symlink"
  fi
  BROWSER_POINTER_TMP_DIR="$(mktemp -d "$BW_BROWSERS_ROOT/.browser-workbench-pointer.publish.XXXXXX")"
  ln -s -- ".generations/$(basename -- "$BROWSER_GENERATION")" "$BROWSER_POINTER_TMP_DIR/current"
  BROWSER_POINTER_SWAP_STARTED=1
  mv -Tf -- "$BROWSER_POINTER_TMP_DIR/current" "$BW_BROWSERS_ROOT/current"
  rmdir -- "$BROWSER_POINTER_TMP_DIR"
  BROWSER_POINTER_TMP_DIR=""
fi

bw_set_browser_active_path || die "published browser pointer is invalid: $BW_BROWSER_POINTER_ERROR"
export PLAYWRIGHT_BROWSERS_PATH="$BW_BROWSERS_PATH"
final_browser="$($BW_NODE -e 'const {chromium}=require(process.argv[1]);process.stdout.write(chromium.executablePath())' "$stage_playwright_package" 2>/dev/null || true)"
[[ -n "$final_browser" && -x "$final_browser" ]] || die "published browser cache did not validate"

GENERATION_ROOT="$BW_RUNTIME_DIR/.generations"
[[ ! -L "$GENERATION_ROOT" ]] || die "runtime generation root must not be a symlink"
mkdir -p -- "$GENERATION_ROOT"
[[ "$BW_RUNTIME_CUSTOM" == 1 ]] || chmod 0700 -- "$GENERATION_ROOT"
RUNTIME_GENERATION="$(mktemp -d "$GENERATION_ROOT/runtime.XXXXXX")"
rmdir -- "$RUNTIME_GENERATION"
mv -- "$STAGE_RUNTIME" "$RUNTIME_GENERATION"
STAGE_RUNTIME=""

if [[ -L "$BW_RUNTIME_DIR/current" ]]; then
  RUNTIME_HAD_POINTER=1
  RUNTIME_PREVIOUS_TARGET="$(readlink -- "$BW_RUNTIME_DIR/current")"
elif [[ -e "$BW_RUNTIME_DIR/current" ]]; then
  die "runtime current pointer must be a symlink"
fi
RUNTIME_POINTER_TMP_DIR="$(mktemp -d "$BW_RUNTIME_DIR/.browser-workbench-pointer.publish.XXXXXX")"
ln -s -- ".generations/$(basename -- "$RUNTIME_GENERATION")" "$RUNTIME_POINTER_TMP_DIR/current"
RUNTIME_POINTER_SWAP_STARTED=1
mv -Tf -- "$RUNTIME_POINTER_TMP_DIR/current" "$BW_RUNTIME_DIR/current"
rmdir -- "$RUNTIME_POINTER_TMP_DIR"
RUNTIME_POINTER_TMP_DIR=""

bw_set_runtime_derived_paths || die "published runtime pointer is invalid: $BW_RUNTIME_POINTER_ERROR"
bw_validate_runtime || die "published runtime failed validation: $BW_RUNTIME_ERROR"
bw_chromium_ready || die "published Chromium failed validation"
SETUP_SUCCESS=1
printf 'Browser Workbench setup complete (@playwright/mcp %s, Playwright %s).\n' "$BW_MCP_VERSION" "$BW_PLAYWRIGHT_VERSION"
