#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() {
  printf 'package-marketplace test: %s\n' "$*" >&2
  exit 1
}

for command in git python3 tar zip unzip zipinfo cmp; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/browser-workbench-package-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REPO="$TEST_ROOT/clone-alpha"
SECOND_REPO="$TEST_ROOT/a-different-clone-name"
ARCHIVE_ROOT='fixture-marketplace'
OUTSIDE="$TEST_ROOT/outside-sentinel.txt"
mkdir -p \
  "$REPO/.agents/plugins" \
  "$REPO/plugins/browser-workbench/.codex-plugin" \
  "$REPO/plugins/browser-workbench/scripts" \
  "$REPO/plugins/browser-workbench/skills/browser-workbench/references"

cp -- "$SCRIPT_DIR/package-marketplace.sh" \
  "$REPO/plugins/browser-workbench/scripts/package-marketplace.sh"
printf '%s\n' '.env.local' >"$REPO/.gitignore"
printf '%s\n' '{"name":"fixture-marketplace","plugins":[]}' >"$REPO/.agents/plugins/marketplace.json"
printf '%s\n' 'fixture license' >"$REPO/LICENSE"
printf '%s\n' 'committed readme' >"$REPO/README.md"
printf '%s\n' 'fixture security' >"$REPO/SECURITY.md"
printf '%s\n' '{"name":"fixture"}' >"$REPO/plugins/browser-workbench/.codex-plugin/plugin.json"
printf '%s\n' '{}' >"$REPO/plugins/browser-workbench/.mcp.json"
printf '%s\n' 'fixture skill' >"$REPO/plugins/browser-workbench/skills/browser-workbench/SKILL.md"
printf '%s\n' 'fixture reference' >"$REPO/plugins/browser-workbench/skills/browser-workbench/references/setup.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$REPO/plugins/browser-workbench/scripts/run.sh"
chmod 0755 \
  "$REPO/plugins/browser-workbench/scripts/package-marketplace.sh" \
  "$REPO/plugins/browser-workbench/scripts/run.sh"

git -C "$REPO" init -q
git -C "$REPO" config user.name 'Packaging Test'
git -C "$REPO" config user.email 'packaging-test@example.invalid'
git -C "$REPO" add .
git -C "$REPO" commit -q -m 'fixture'
git clone -q "$REPO" "$SECOND_REPO"

# None of these working-tree-only entries may cross the Git source boundary.
printf '%s\n' 'not a real secret' >"$REPO/.env.local"
printf '%s\n' 'arbitrary untracked content' >"$REPO/arbitrary-untracked.txt"
printf '%s\n' 'external sentinel content' >"$OUTSIDE"
ln -s "$OUTSIDE" "$REPO/plugins/browser-workbench/scripts/external-link"
printf '%s\n' 'locally modified readme' >"$REPO/README.md"
git -C "$REPO" check-ignore -q .env.local || fail ".env.local fixture is not ignored"

ARCHIVE_ONE="$TEST_ROOT/one.zip"
ARCHIVE_TWO="$TEST_ROOT/two.zip"
DIAGNOSTICS="$TEST_ROOT/diagnostics.txt"
(cd -- "$REPO" && bash plugins/browser-workbench/scripts/package-marketplace.sh "$ARCHIVE_ONE") \
  2>"$DIAGNOSTICS"
(cd -- "$SECOND_REPO" && bash plugins/browser-workbench/scripts/package-marketplace.sh "$ARCHIVE_TWO") \
  2>>"$DIAGNOSTICS"
cmp -s "$ARCHIVE_ONE" "$ARCHIVE_TWO" || \
  fail "same commit packaged from different clone basenames differs byte-for-byte"

grep -Fq 'tracked index/worktree changes are ignored; packaging committed HEAD' "$DIAGNOSTICS" || \
  fail "tracked-change diagnostic was not emitted"

ARCHIVE_FILES="$TEST_ROOT/archive-files.txt"
EXPECTED_FILES="$TEST_ROOT/expected-files.txt"
unzip -Z1 "$ARCHIVE_ONE" | sed -n '/\/$/!p' | LC_ALL=C sort >"$ARCHIVE_FILES"
git -C "$REPO" ls-tree -r --name-only HEAD -- \
  .agents/plugins/marketplace.json LICENSE README.md SECURITY.md plugins/browser-workbench |
  sed "s|^|$ARCHIVE_ROOT/|" | LC_ALL=C sort >"$EXPECTED_FILES"
cmp -s "$EXPECTED_FILES" "$ARCHIVE_FILES" || {
  diff -u "$EXPECTED_FILES" "$ARCHIVE_FILES" >&2 || true
  fail "archive file set does not match the committed allowlist"
}

if grep -Eq '(\.env\.local|arbitrary-untracked|external-link|outside-sentinel|/\.git/)' "$ARCHIVE_FILES"; then
  fail "working-tree-only or repository metadata entered the archive"
fi

README_CONTENT="$(unzip -p "$ARCHIVE_ONE" "$ARCHIVE_ROOT/README.md")"
[[ "$README_CONTENT" == 'committed readme' ]] || fail "archive did not use committed HEAD content"

EXEC_MODE="$(zipinfo -l "$ARCHIVE_ONE" "$ARCHIVE_ROOT/plugins/browser-workbench/scripts/run.sh" | tail -n 1 | awk '{print $1}')"
DATA_MODE="$(zipinfo -l "$ARCHIVE_ONE" "$ARCHIVE_ROOT/README.md" | tail -n 1 | awk '{print $1}')"
[[ "$EXEC_MODE" == '-rwxr-xr-x' ]] || fail "executable mode was not preserved: $EXEC_MODE"
[[ "$DATA_MODE" == '-rw-r--r--' ]] || fail "regular file mode was not normalized: $DATA_MODE"

# The archive root comes from committed manifest data, but only a safe slug is
# accepted. Committed paths that look like secrets are rejected as well.
git -C "$SECOND_REPO" config user.name 'Packaging Test'
git -C "$SECOND_REPO" config user.email 'packaging-test@example.invalid'
printf '%s\n' '{"name":"../unsafe","plugins":[]}' >"$SECOND_REPO/.agents/plugins/marketplace.json"
git -C "$SECOND_REPO" add .agents/plugins/marketplace.json
git -C "$SECOND_REPO" commit -q -m 'unsafe marketplace name'
if (cd -- "$SECOND_REPO" && bash plugins/browser-workbench/scripts/package-marketplace.sh "$TEST_ROOT/unsafe.zip") \
  >"$TEST_ROOT/unsafe.stdout" 2>"$TEST_ROOT/unsafe.stderr"; then
  fail "unsafe committed marketplace name was accepted"
fi
grep -Fq 'unsafe marketplace name in committed manifest' "$TEST_ROOT/unsafe.stderr" || \
  fail "unsafe marketplace name rejection was not diagnosed"

git -C "$SECOND_REPO" restore --source=HEAD^ .agents/plugins/marketplace.json
git -C "$SECOND_REPO" commit -q -am 'restore safe marketplace name'
printf '%s\n' 'not a real secret' >"$SECOND_REPO/plugins/browser-workbench/.env"
git -C "$SECOND_REPO" add -f plugins/browser-workbench/.env
git -C "$SECOND_REPO" commit -q -m 'force-added secret pattern'
if (cd -- "$SECOND_REPO" && bash plugins/browser-workbench/scripts/package-marketplace.sh "$TEST_ROOT/secret.zip") \
  >"$TEST_ROOT/secret.stdout" 2>"$TEST_ROOT/secret.stderr"; then
  fail "committed secret-pattern path was accepted"
fi
grep -Fq 'refusing committed secret-pattern path: plugins/browser-workbench/.env' \
  "$TEST_ROOT/secret.stderr" || fail "committed secret-pattern rejection was not diagnosed"

# A symlink committed inside the allowlist must stop packaging before Git can
# materialize or zip it.
git -C "$REPO" restore README.md
git -C "$REPO" add plugins/browser-workbench/scripts/external-link
git -C "$REPO" commit -q -m 'tracked symlink'
if (cd -- "$REPO" && bash plugins/browser-workbench/scripts/package-marketplace.sh "$TEST_ROOT/rejected.zip") \
  >"$TEST_ROOT/rejected.stdout" 2>"$TEST_ROOT/rejected.stderr"; then
  fail "tracked symlink was accepted"
fi
grep -Fq 'unsupported Git entry' "$TEST_ROOT/rejected.stderr" || \
  fail "tracked symlink rejection was not diagnosed"

printf '%s\n' 'package-marketplace test: ok'
