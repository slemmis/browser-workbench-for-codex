#!/usr/bin/env bash
set -euo pipefail

umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
POWERSHELL_SOURCE="$SCRIPT_DIR/windows-image-bridge.ps1"
PNG_VALIDATOR="$SCRIPT_DIR/validate-png.mjs"
MAX_SOURCE_BYTES=$((25 * 1024 * 1024))
MAX_ENCODED_BYTES=$MAX_SOURCE_BYTES
MAX_DIMENSION=20000
MAX_PIXELS=25000000
DEFAULT_TIMEOUT_SECONDS=15
MAX_TIMEOUT_SECONDS=120
WINDOWS_IMAGE_NAME_REGEX='^windows-image-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.png$'

TEMP_PATH=""
TEMP_ID=""
ERROR_PATH=""
BRIDGE_ROOT_ID=""

cleanup_temporary_files() {
  if [[ -n "$TEMP_PATH" && -e "$TEMP_PATH" && ! -L "$TEMP_PATH" ]]; then
    rm -f -- "$TEMP_PATH"
  fi
  if [[ -n "$ERROR_PATH" && -e "$ERROR_PATH" && ! -L "$ERROR_PATH" ]]; then
    rm -f -- "$ERROR_PATH"
  fi
}

trap cleanup_temporary_files EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

die() {
  printf 'browser-workbench Windows image bridge: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  windows-image-bridge.sh clipboard [--dry-run]
  windows-image-bridge.sh file <absolute-Windows-path> [--dry-run]
  windows-image-bridge.sh list
  windows-image-bridge.sh cleanup (--all | --older-than-days N) [--dry-run]
  windows-image-bridge.sh doctor
USAGE
}

is_wsl() {
  [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version
}

cache_root_for_bridge() {
  local home_dir="${HOME:-}"
  [[ "$home_dir" == /* ]] || die "HOME must be an absolute path to locate the Windows image cache"
  local cache_home="${XDG_CACHE_HOME:-$home_dir/.cache}"
  [[ "$cache_home" == /* ]] || die "XDG_CACHE_HOME must be an absolute path"
  command -v realpath >/dev/null 2>&1 || die "realpath is required"
  local candidate normalized
  candidate="${cache_home%/}/browser-workbench/windows-images"
  [[ "$candidate" == /* ]] || candidate="/$candidate"
  normalized="$(realpath -m -- "$candidate")" || die "the Windows image cache path could not be normalized"
  [[ "$candidate" == "$normalized" ]] || die "the Windows image cache path must not contain symlinks or dot components"
  printf '%s\n' "$normalized"
}

bridge_root_is_symlink() {
  [[ -L "$BRIDGE_ROOT" ]]
}

assert_bridge_root_path() {
  local normalized
  normalized="$(realpath -m -- "$BRIDGE_ROOT")" || die "cache root could not be resolved"
  [[ "$normalized" == "$BRIDGE_ROOT" ]] || die "cache root or one of its parents must not be a symlink"
  if [[ -n "$BRIDGE_ROOT_ID" ]]; then
    [[ -d "$BRIDGE_ROOT" && ! -L "$BRIDGE_ROOT" ]] || die "cache root changed during the operation"
    [[ "$(stat -Lc '%d:%i' -- "$BRIDGE_ROOT")" == "$BRIDGE_ROOT_ID" ]] || die "cache root changed during the operation"
  fi
}

ensure_bridge_root() {
  assert_bridge_root_path
  if bridge_root_is_symlink; then
    die "cache root must not be a symlink"
  fi
  mkdir -p -- "$BRIDGE_ROOT"
  assert_bridge_root_path
  [[ -d "$BRIDGE_ROOT" && ! -L "$BRIDGE_ROOT" ]] || die "cache root is not a regular directory"
  chmod 700 -- "$BRIDGE_ROOT"
  [[ "$(stat -c '%a' -- "$BRIDGE_ROOT")" == 700 ]] || die "cache root permissions could not be set to 0700"
  BRIDGE_ROOT_ID="$(stat -Lc '%d:%i' -- "$BRIDGE_ROOT")"
  assert_bridge_root_path
}

assert_temporary_identity() {
  [[ -n "$TEMP_PATH" && -n "$TEMP_ID" ]] || die "temporary image state is incomplete"
  [[ -f "$TEMP_PATH" && ! -L "$TEMP_PATH" ]] || die "temporary image changed during the operation"
  [[ "$(stat -Lc '%d:%i' -- "$TEMP_PATH")" == "$TEMP_ID" ]] || die "temporary image changed during the operation"
}

node_path=""
require_node20() {
  if [[ -z "$node_path" ]]; then
    node_path="$(command -v node 2>/dev/null || true)"
  fi
  [[ -n "$node_path" ]] || die "Node.js 20 or newer is required for PNG validation"
  local version major
  version="$($node_path -p 'process.versions.node')"
  major="${version%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$major" -ge 20 ]] || die "Node.js 20 or newer is required for PNG validation (found $version)"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
}

timeout_seconds="${BROWSER_WORKBENCH_WINDOWS_IMAGE_TIMEOUT_SECONDS:-$DEFAULT_TIMEOUT_SECONDS}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ && "$timeout_seconds" -le "$MAX_TIMEOUT_SECONDS" ]] || die "BROWSER_WORKBENCH_WINDOWS_IMAGE_TIMEOUT_SECONDS must be an integer from 1 to $MAX_TIMEOUT_SECONDS"

powershell_command="powershell.exe"
find_powershell() {
  if [[ "$powershell_command" == */* ]]; then
    [[ -x "$powershell_command" ]] || return 1
    printf '%s\n' "$powershell_command"
  else
    command -v "$powershell_command" 2>/dev/null
  fi
}

powershell_source_argument() {
  local powershell_name="${powershell_command##*/}"
  local source_path="$POWERSHELL_SOURCE"
  case "$powershell_name" in
    powershell.exe|pwsh.exe)
      if is_wsl && command -v wslpath >/dev/null 2>&1; then
        source_path="$(wslpath -w -- "$POWERSHELL_SOURCE")" || die "the fixed PowerShell bridge path could not be translated"
      fi
      ;;
  esac
  printf '%s\n' "$source_path"
}

require_wsl_for_windows_access() {
  local executable="$1"
  if [[ "${BROWSER_WORKBENCH_BRIDGE_TESTING:-0}" == 1 && "${BROWSER_WORKBENCH_BRIDGE_TEST_ROOT:-}" == /* ]]; then
    local test_root executable_path
    test_root="$(realpath -m -- "$BROWSER_WORKBENCH_BRIDGE_TEST_ROOT")" || die "test root could not be resolved"
    executable_path="$(realpath -e -- "$executable")" || die "test PowerShell seam could not be resolved"
    [[ "$executable_path" == "$test_root"/* ]] || die "test PowerShell executable must be inside the declared test root"
  fi
  if is_wsl; then
    return 0
  fi
  if [[ "${BROWSER_WORKBENCH_BRIDGE_TESTING:-0}" == 1 && "${BROWSER_WORKBENCH_BRIDGE_TEST_ROOT:-}" == /* ]]; then
    return 0
  fi
  die "clipboard and file modes require WSL"
}

validate_file_argument() {
  local input_path="$1"
  local tail
  [[ "$input_path" =~ ^[A-Za-z]:[\\/].+ ]] || die "file mode requires an absolute local Windows drive path"
  [[ ! "$input_path" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] || die "URI paths are not allowed"
  [[ "$input_path" != \\* && "$input_path" != //* ]] || die "UNC, network, and device paths are not allowed"
  tail="${input_path:2}"
  [[ ! "$tail" =~ (^|[\\/])([.?])([\\/]|$) ]] || die "device paths are not allowed"
  [[ "$tail" != *:* ]] || die "alternate data stream paths are not allowed"
}

run_windows_capture() {
  local mode="$1"
  local input_path="${2:-}"
  local raw encoded status source_argument
  source_argument="$(powershell_source_argument)"
  ERROR_PATH="$(mktemp "${TMPDIR:-/tmp}/browser-workbench-windows-image-error.XXXXXX")"
  set +e
  raw="$(timeout --signal=TERM --kill-after=2s "$timeout_seconds" "$POWERSHELL_EXECUTABLE" \
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA \
    -File "$source_argument" "$mode" "$input_path" 2>"$ERROR_PATH")"
  status=$?
  set -e
  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    die "Windows PowerShell call timed out after ${timeout_seconds}s"
  fi
  if [[ "$status" -ne 0 ]]; then
    if [[ -s "$ERROR_PATH" ]]; then
      sed 's/[[:cntrl:]]//g' "$ERROR_PATH" >&2 || true
    fi
    die "Windows PowerShell could not provide an image"
  fi

  encoded="$(printf '%s' "$raw" | tr -d '\r\n')"
  [[ -n "$encoded" ]] || die "Windows PowerShell returned no image data"
  [[ "${#encoded}" -le $((4 * ((MAX_ENCODED_BYTES + 2) / 3))) ]] || die "transported image exceeds the encoded size limit"
  [[ "$encoded" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || die "Windows PowerShell returned invalid image data"
  [[ $(( ${#encoded} % 4 )) -eq 0 ]] || die "Windows PowerShell returned truncated image data"
  if ! printf '%s' "$encoded" | base64 --decode > "$TEMP_PATH"; then
    die "transported image could not be decoded"
  fi
  assert_temporary_identity
}

validate_temporary_png() {
  local metadata
  assert_temporary_identity
  if ! metadata="$($node_path "$PNG_VALIDATOR" --json "$TEMP_PATH" 2>"$ERROR_PATH")"; then
    if [[ -s "$ERROR_PATH" ]]; then
      sed 's/[[:cntrl:]]//g' "$ERROR_PATH" >&2 || true
    fi
    die "transported image failed PNG validation"
  fi
  assert_temporary_identity
  printf '%s' "$metadata"
}

publish_image() {
  local metadata="$1"
  local temp_name token final_path timestamp
  temp_name="$(basename -- "$TEMP_PATH")"
  token="${temp_name//[^A-Za-z0-9]/}"
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  final_path="$BRIDGE_ROOT/windows-image-${timestamp}-${token}.png"
  while [[ -e "$final_path" || -L "$final_path" ]]; do
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    token="${token}${RANDOM}"
    final_path="$BRIDGE_ROOT/windows-image-${timestamp}-${token}.png"
  done
  assert_bridge_root_path
  assert_temporary_identity
  chmod 600 -- "$TEMP_PATH"
  [[ "$(stat -c '%a' -- "$TEMP_PATH")" == 600 ]] || die "image permissions could not be set to 0600"
  mv -T -- "$TEMP_PATH" "$final_path"
  TEMP_PATH=""
  TEMP_ID=""
  assert_bridge_root_path
  [[ -f "$final_path" && ! -L "$final_path" ]] || die "published image is not a regular file"
  [[ "$(stat -c '%a' -- "$final_path")" == 600 ]] || die "published image permissions are not 0600"
  "$node_path" - "$final_path" "$metadata" <<'NODE'
const filePath = process.argv[2];
const metadata = JSON.parse(process.argv[3]);
process.stdout.write(`${JSON.stringify({
  path: filePath,
  mime: "image/png",
  width: metadata.width,
  height: metadata.height,
  bytes: metadata.bytes,
})}\n`);
NODE
}

capture_image() {
  local mode="$1"
  local input_path="${2:-}"
  if [[ "$mode" == file ]]; then
    validate_file_argument "$input_path"
  fi
  require_node20
  POWERSHELL_EXECUTABLE="$(find_powershell || true)"
  [[ -n "$POWERSHELL_EXECUTABLE" ]] || die "inbox Windows PowerShell 5.1 (powershell.exe) was not found"
  require_wsl_for_windows_access "$POWERSHELL_EXECUTABLE"
  require_command timeout
  require_command base64
  ensure_bridge_root
  TEMP_PATH="$(mktemp "$BRIDGE_ROOT/.windows-image.XXXXXXXX.tmp")"
  TEMP_ID="$(stat -Lc '%d:%i' -- "$TEMP_PATH")"
  ERROR_PATH=""
  run_windows_capture "$mode" "$input_path"
  local metadata
  metadata="$(validate_temporary_png)"
  publish_image "$metadata"
}

is_bridge_file_name() {
  [[ "$(basename -- "$1")" =~ $WINDOWS_IMAGE_NAME_REGEX ]]
}

list_files() {
  require_node20
  local -a entries=()
  if [[ -e "$BRIDGE_ROOT" ]]; then
    assert_bridge_root_path
    bridge_root_is_symlink && die "cache root must not be a symlink"
    [[ -d "$BRIDGE_ROOT" ]] || die "cache root is not a directory"
    local candidate metadata
    while IFS= read -r -d '' candidate; do
      [[ -f "$candidate" && ! -L "$candidate" ]] || continue
      is_bridge_file_name "$candidate" || continue
      if metadata="$($node_path "$PNG_VALIDATOR" --json "$candidate" 2>/dev/null)"; then
        entries+=("$metadata")
      fi
    done < <(find -P "$BRIDGE_ROOT" -mindepth 1 -maxdepth 1 -type f -name 'windows-image-*.png' -print0)
  elif [[ -L "$BRIDGE_ROOT" ]]; then
    die "cache root must not be a symlink"
  fi
  "$node_path" - "${entries[@]}" <<'NODE'
const files = process.argv.slice(2).map((entry) => JSON.parse(entry));
process.stdout.write(`${JSON.stringify({ files })}\n`);
NODE
}

cleanup_files() {
  local policy="$1"
  local older_days="${2:-}"
  local -a removed=()
  local candidate now cutoff mtime
  if [[ -e "$BRIDGE_ROOT" ]]; then
    assert_bridge_root_path
    bridge_root_is_symlink && die "cache root must not be a symlink"
    [[ -d "$BRIDGE_ROOT" ]] || die "cache root is not a directory"
    now="$(date +%s)"
    cutoff=$((now - older_days * 86400))
    while IFS= read -r -d '' candidate; do
      [[ -f "$candidate" && ! -L "$candidate" ]] || continue
      is_bridge_file_name "$candidate" || continue
      if [[ "$policy" == older ]]; then
        mtime="$(stat -c '%Y' -- "$candidate")"
        [[ "$mtime" -lt "$cutoff" ]] || continue
      fi
      if [[ "$(dirname -- "$candidate")" != "$BRIDGE_ROOT" ]]; then
        die "refusing to remove a file outside the bridge cache root"
      fi
      if [[ "$DRY_RUN" -eq 0 ]]; then
        rm -f -- "$candidate"
      fi
      removed+=("$candidate")
    done < <(find -P "$BRIDGE_ROOT" -mindepth 1 -maxdepth 1 -type f -name 'windows-image-*.png' -print0)
  elif [[ -L "$BRIDGE_ROOT" ]]; then
    die "cache root must not be a symlink"
  fi
  "$node_path" - "$DRY_RUN" "${removed[@]}" <<'NODE'
const dryRun = process.argv[2] === "1";
const paths = process.argv.slice(3);
process.stdout.write(`${JSON.stringify({ dry_run: dryRun, removed: paths.length, paths })}\n`);
NODE
}

doctor() {
  local wsl_status powershell_status root_status powershell_path
  if is_wsl; then wsl_status="yes"; else wsl_status="no"; fi
  if powershell_path="$(find_powershell || true)"; then
    [[ -n "$powershell_path" ]] && powershell_status="available ($powershell_path)" || powershell_status="missing"
  else
    powershell_status="missing"
  fi
  if [[ -L "$BRIDGE_ROOT" ]]; then
    root_status="unsafe symlink"
  elif [[ -d "$BRIDGE_ROOT" ]]; then
    root_status="present"
  else
    root_status="not created"
  fi
  printf 'Browser Workbench Windows image bridge doctor (read-only)\n'
  printf 'WSL: %s\n' "$wsl_status"
  printf 'Windows PowerShell 5.1: %s\n' "$powershell_status"
  printf 'Cache root: %s (%s)\n' "$BRIDGE_ROOT" "$root_status"
  printf 'Limits: source/PNG <= %d bytes; dimensions <= %dx%d; pixels <= %d\n' "$MAX_SOURCE_BYTES" "$MAX_DIMENSION" "$MAX_DIMENSION" "$MAX_PIXELS"
  printf 'Timeout: %ss (maximum %ss)\n' "$timeout_seconds" "$MAX_TIMEOUT_SECONDS"
  printf 'Clipboard access: only explicit clipboard command; no watcher or fallback\n'
}

DRY_RUN=0
COMMAND_ARGS=()
for argument in "$@"; do
  if [[ "$argument" == '--dry-run' ]]; then
    DRY_RUN=1
  else
    COMMAND_ARGS+=("$argument")
  fi
done

BRIDGE_ROOT="$(cache_root_for_bridge)"
if [[ "${#COMMAND_ARGS[@]}" -lt 1 ]]; then
  usage
  exit 2
fi

COMMAND="${COMMAND_ARGS[0]}"
COMMAND_ARGS=("${COMMAND_ARGS[@]:1}")

case "$COMMAND" in
  clipboard)
    [[ "${#COMMAND_ARGS[@]}" -eq 0 || ("${#COMMAND_ARGS[@]}" -eq 1 && -z "${COMMAND_ARGS[0]}") ]] || { usage; exit 2; }
    if [[ "$DRY_RUN" -eq 1 ]]; then
      require_node20
      printf '%s\n' "$("$node_path" - "$BRIDGE_ROOT" "$timeout_seconds" <<'NODE'
const [cacheRoot, timeout] = process.argv.slice(2);
process.stdout.write(`${JSON.stringify({ command: "clipboard", cache_root: cacheRoot, timeout_seconds: Number(timeout), dry_run: true })}\n`);
NODE
)"
    else
      capture_image clipboard
    fi
    ;;
  file)
    [[ "${#COMMAND_ARGS[@]}" -eq 1 ]] || { usage; exit 2; }
    validate_file_argument "${COMMAND_ARGS[0]}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      require_node20
      printf '%s\n' "$("$node_path" - "$BRIDGE_ROOT" "$timeout_seconds" "${COMMAND_ARGS[0]}" <<'NODE'
const [cacheRoot, timeout, inputPath] = process.argv.slice(2);
process.stdout.write(`${JSON.stringify({ command: "file", cache_root: cacheRoot, timeout_seconds: Number(timeout), path: inputPath, dry_run: true })}\n`);
NODE
)"
    else
      capture_image file "${COMMAND_ARGS[0]}"
    fi
    ;;
  list)
    [[ "${#COMMAND_ARGS[@]}" -eq 0 ]] || { usage; exit 2; }
    list_files
    ;;
  cleanup)
    [[ "${#COMMAND_ARGS[@]}" -ge 1 ]] || { usage; exit 2; }
    cleanup_policy=""
    cleanup_days=""
    cleanup_index=0
    while [[ "$cleanup_index" -lt "${#COMMAND_ARGS[@]}" ]]; do
      case "${COMMAND_ARGS[$cleanup_index]}" in
        --all)
          [[ -z "$cleanup_policy" ]] || die "cleanup accepts exactly one explicit policy"
          cleanup_policy="all"
          ;;
        --older-than-days)
          cleanup_index=$((cleanup_index + 1))
          [[ "$cleanup_index" -lt "${#COMMAND_ARGS[@]}" ]] || die "--older-than-days requires N"
          cleanup_days="${COMMAND_ARGS[$cleanup_index]}"
          [[ "$cleanup_days" =~ ^[0-9]+$ && "$cleanup_days" -le 36500 ]] || die "--older-than-days N must be an integer from 0 to 36500"
          [[ -z "$cleanup_policy" ]] || die "cleanup accepts exactly one explicit policy"
          cleanup_policy="older"
          ;;
        *) usage; exit 2 ;;
      esac
      cleanup_index=$((cleanup_index + 1))
    done
    [[ -n "$cleanup_policy" ]] || die "cleanup requires --all or --older-than-days N"
    require_node20
    cleanup_files "$cleanup_policy" "${cleanup_days:-0}"
    ;;
  doctor)
    [[ "${#COMMAND_ARGS[@]}" -eq 0 ]] || { usage; exit 2; }
    doctor
    ;;
  --help|-h)
    usage >&1
    ;;
  *)
    die "unsupported command '$COMMAND'"
    ;;
esac
