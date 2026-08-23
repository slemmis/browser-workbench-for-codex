#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MARKETPLACE_ROOT="$(cd -- "$PLUGIN_DIR/../.." && pwd -P)"
MARKETPLACE_NAME="$(basename -- "$MARKETPLACE_ROOT")"
OUTPUT_PATH="${1:-$MARKETPLACE_ROOT/../$MARKETPLACE_NAME.zip}"

die() {
  printf 'browser-workbench package: %s\n' "$*" >&2
  exit 1
}

command -v tar >/dev/null 2>&1 || die "tar is required"
command -v zip >/dev/null 2>&1 || die "zip is required"

STAGE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/browser-workbench-package.XXXXXX")"
STAGE_ROOT="$STAGE_PARENT/$MARKETPLACE_NAME"
mkdir -p "$STAGE_ROOT"
trap 'rm -rf -- "$STAGE_PARENT"' EXIT

# Copy through tar so generated runtimes, caches, outputs, VCS metadata, and
# secret files cannot enter a distributable package even if a developer leaves
# them behind. Normalize archive metadata so repeated packages are byte-stable.
(
  cd -- "$MARKETPLACE_ROOT"
  tar -cf - \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --exclude='./.git' \
    --exclude='*/.git' \
    --exclude='./.runtime' \
    --exclude='*/.runtime' \
    --exclude='./.playwright-mcp' \
    --exclude='*/.playwright-mcp' \
    --exclude='./.cache' \
    --exclude='*/.cache' \
    --exclude='./cache' \
    --exclude='*/cache' \
    --exclude='./browsers' \
    --exclude='*/browsers' \
    --exclude='./profiles' \
    --exclude='*/profiles' \
    --exclude='./output' \
    --exclude='*/output' \
    --exclude='./outputs' \
    --exclude='*/outputs' \
    --exclude='*/__pycache__' \
    --exclude='./__pycache__' \
    --exclude='./.secrets' \
    --exclude='*/.secrets' \
    --exclude='./secrets' \
    --exclude='*/secrets' \
    --exclude='*.env' \
    --exclude='*.secret' \
    --exclude='*.secrets' \
    --exclude='*/.npmrc' \
    --exclude='./.npmrc' \
    --exclude='*.zip' \
    .
) | tar -C "$STAGE_ROOT" -xf -

# DrvFS commonly reports every source file as 0777. Normalize the archive's
# Unix mode bits explicitly so extraction on Linux is deterministic.
find "$STAGE_ROOT" -type d -exec chmod 0755 {} +
find "$STAGE_ROOT" -type f -exec chmod 0644 {} +
find "$STAGE_ROOT" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0755 {} +

OUTPUT_DIR="$(dirname -- "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_PATH="$(cd -- "$OUTPUT_DIR" && pwd -P)/$(basename -- "$OUTPUT_PATH")"
ZIP_TEMP="$STAGE_PARENT/$MARKETPLACE_NAME.zip"
(
  cd -- "$STAGE_PARENT"
  zip -r -q -X "$ZIP_TEMP" "$MARKETPLACE_NAME"
)
mv -f -- "$ZIP_TEMP" "$OUTPUT_PATH"
printf 'Packaged %s\n' "$OUTPUT_PATH"
