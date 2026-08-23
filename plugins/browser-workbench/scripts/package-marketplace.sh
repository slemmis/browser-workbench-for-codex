#!/usr/bin/env bash
set -euo pipefail
export TZ=UTC

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MARKETPLACE_ROOT="$(cd -- "$PLUGIN_DIR/../.." && pwd -P)"

die() {
  printf 'browser-workbench package: %s\n' "$*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
command -v zip >/dev/null 2>&1 || die "zip is required"

GIT_ROOT="$(git -C "$MARKETPLACE_ROOT" rev-parse --show-toplevel 2>/dev/null)" || \
  die "marketplace root is not a Git worktree"
GIT_ROOT="$(cd -- "$GIT_ROOT" && pwd -P)"
[[ "$GIT_ROOT" == "$MARKETPLACE_ROOT" ]] || \
  die "marketplace root must be the Git worktree root"

SOURCE_COMMIT="$(git -C "$MARKETPLACE_ROOT" rev-parse --verify 'HEAD^{commit}')" || \
  die "HEAD does not resolve to a commit"
MARKETPLACE_NAME="$(
  git -C "$MARKETPLACE_ROOT" show "$SOURCE_COMMIT:.agents/plugins/marketplace.json" |
    python3 -c 'import json, sys; name = json.load(sys.stdin).get("name"); sys.exit(1) if not isinstance(name, str) else print(name)'
)" || die "committed marketplace manifest has no valid string name"
[[ "$MARKETPLACE_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] || \
  die "unsafe marketplace name in committed manifest: $MARKETPLACE_NAME"
OUTPUT_PATH="${1:-$MARKETPLACE_ROOT/../$MARKETPLACE_NAME.zip}"

# A release is always made from committed HEAD. This makes ignored and
# untracked files in a developer checkout irrelevant, and avoids silently
# combining staged and unstaged content in one archive.
if ! git -C "$MARKETPLACE_ROOT" diff --quiet HEAD --; then
  printf '%s\n' \
    'browser-workbench package: tracked index/worktree changes are ignored; packaging committed HEAD' >&2
fi
printf 'browser-workbench package: source HEAD %s\n' "$SOURCE_COMMIT" >&2

# These are the only repository areas needed to install and understand the
# marketplace. Files below the plugin directory remain Git-controlled so new
# plugin scripts and skill references are included without broadening the
# package to CI, caches, or repository administration files.
PACKAGE_PATHS=(
  '.agents/plugins/marketplace.json'
  'LICENSE'
  'README.md'
  'SECURITY.md'
  'plugins/browser-workbench'
)
REQUIRED_PATHS=(
  '.agents/plugins/marketplace.json'
  'plugins/browser-workbench/.codex-plugin/plugin.json'
  'plugins/browser-workbench/.mcp.json'
  'plugins/browser-workbench/skills/browser-workbench/SKILL.md'
)

for path in "${REQUIRED_PATHS[@]}"; do
  entry="$(git -C "$MARKETPLACE_ROOT" ls-tree "$SOURCE_COMMIT" -- "$path")"
  [[ -n "$entry" ]] || die "required path is absent from HEAD: $path"
done

ENTRY_COUNT=0
while IFS= read -r -d '' entry; do
  metadata="${entry%%$'\t'*}"
  path="${entry#*$'\t'}"
  read -r mode type object <<<"$metadata"
  [[ "$type" == 'blob' && ( "$mode" == '100644' || "$mode" == '100755' ) ]] || \
    die "unsupported Git entry at $path (mode $mode, type $type); only regular files are packageable"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || \
    die "unsupported newline in package path"
  basename="${path##*/}"
  case "$basename" in
    .env|.env.*|*.pem|*.key|credentials|credentials.*|secret|secret.*|secrets|secrets.*|*.secret|*.secrets)
      die "refusing committed secret-pattern path: $path"
      ;;
  esac
  case "/$path/" in
    */.credentials/*|*/credentials/*|*/.secrets/*|*/secrets/*)
      die "refusing committed secret-pattern path: $path"
      ;;
  esac
  ((ENTRY_COUNT += 1))
done < <(git -C "$MARKETPLACE_ROOT" ls-tree -r -z --full-tree "$SOURCE_COMMIT" -- "${PACKAGE_PATHS[@]}")
(( ENTRY_COUNT > 0 )) || die "HEAD contains no packageable files"

STAGE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/browser-workbench-package.XXXXXX")"
STAGE_ROOT="$STAGE_PARENT/$MARKETPLACE_NAME"
mkdir -p "$STAGE_ROOT"
trap 'rm -rf -- "$STAGE_PARENT"' EXIT

git -C "$MARKETPLACE_ROOT" archive --format=tar "$SOURCE_COMMIT" -- "${PACKAGE_PATHS[@]}" |
  tar -C "$STAGE_ROOT" -xf -

# Normalize timestamps and honor only the two regular-file modes accepted
# above. This avoids host filesystem mode differences (notably DrvFS) while
# retaining the executable intent recorded in Git.
find "$STAGE_ROOT" -type d -exec chmod 0755 {} +
find "$STAGE_ROOT" -exec touch -h -t 198001010000.00 {} +
while IFS= read -r -d '' entry; do
  metadata="${entry%%$'\t'*}"
  path="${entry#*$'\t'}"
  read -r mode _ <<<"$metadata"
  if [[ "$mode" == '100755' ]]; then
    chmod 0755 "$STAGE_ROOT/$path"
  else
    chmod 0644 "$STAGE_ROOT/$path"
  fi
done < <(git -C "$MARKETPLACE_ROOT" ls-tree -r -z --full-tree "$SOURCE_COMMIT" -- "${PACKAGE_PATHS[@]}")

OUTPUT_DIR="$(dirname -- "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_PATH="$(cd -- "$OUTPUT_DIR" && pwd -P)/$(basename -- "$OUTPUT_PATH")"
ZIP_TEMP="$STAGE_PARENT/$MARKETPLACE_NAME.zip"
(
  cd -- "$STAGE_PARENT"
  find "$MARKETPLACE_NAME" -print | LC_ALL=C sort | zip -q -X "$ZIP_TEMP" -@
)
mv -f -- "$ZIP_TEMP" "$OUTPUT_PATH"
printf 'Packaged %s from HEAD %s\n' "$OUTPUT_PATH" "$SOURCE_COMMIT"
