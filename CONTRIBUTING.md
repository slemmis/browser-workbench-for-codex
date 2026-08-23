# Contributing

Thank you for helping improve Browser Workbench for Codex. Please open an issue before a substantial change so the scope and safety impact can be discussed, then send a focused pull request against the [public repository](https://github.com/slemmis/browser-workbench-for-codex).

## Development prerequisites

- Linux or WSL2.
- Node.js 20 or newer, `npm`, and `npx`.
- `python3` for the MCP protocol smoke test.
- Network access for the pinned Playwright MCP package and Chromium download.

## Local checks

From `plugins/browser-workbench`, prepare the user-local runtime and run the checks:

```bash
bash scripts/setup.sh
bash scripts/doctor.sh
bash scripts/smoke-test.sh
bash scripts/mcp-smoke-test.sh
```

Before opening a pull request, also run the static and packaging checks from the repository root:

```bash
python3 -m json.tool .agents/plugins/marketplace.json >/dev/null
python3 -m json.tool plugins/browser-workbench/.codex-plugin/plugin.json >/dev/null
python3 -m json.tool plugins/browser-workbench/.mcp.json >/dev/null
bash -n plugins/browser-workbench/scripts/*.sh
python3 -m py_compile plugins/browser-workbench/scripts/mcp_smoke_test.py
bash plugins/browser-workbench/scripts/package-marketplace.sh "$PWD/../browser-workbench-marketplace.zip"
```

The package script creates a clean archive with normalized Unix modes and excludes local runtimes, browser caches, profiles, outputs, secrets, and Python bytecode. Do not commit generated ZIP files or runtime artifacts.

## Safety expectations

Keep the isolated mode and confirmation boundaries intact. Page content, browser output, CDP data, profiles, and downloaded files are untrusted. Never add credentials, secret URLs, cookies, storage state, or personal browser data to source, fixtures, screenshots, logs, or tests. Setup must remain explicit, idempotent, and free of `sudo` or implicit system-package changes.

If a change affects browser interaction, attachment, profiles, downloads, or external side effects, explain the trust boundary and verification in the pull request. Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Pull requests

Keep changes small and explain:

- what behavior or documentation changed;
- which commands were run and their actual results;
- any environment-dependent checks that were skipped; and
- any compatibility or security trade-offs.

Please do not commit generated dependencies, browser binaries, cache contents, or release archives.
