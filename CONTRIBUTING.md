# Contributing

Thank you for helping improve Browser Workbench for Codex. Please open an issue before a substantial change so the scope and safety impact can be discussed, then send a focused pull request against the [public repository](https://github.com/slemmis/browser-workbench-for-codex).

## Development prerequisites

- Linux or WSL2.
- Node.js 20 or newer and `npm`; `npx` is not used.
- `python3` for the MCP protocol smoke test.
- Network access for the pinned Playwright MCP package and Chromium download.

## Local checks

From `plugins/browser-workbench`, prepare the user-local runtime and run the checks:

```bash
bash scripts/setup.sh
bash scripts/doctor.sh
bash scripts/smoke-test.sh
bash scripts/mcp-smoke-test.sh
bash scripts/windows-image-bridge-test.sh
```

Before opening a pull request, run the hermetic/static suite from the repository root. It does not download npm packages or Chromium, touch the real clipboard, install/remove a Codex plugin, or mutate the normal user cache. ShellCheck must be exactly 0.10.0; the following fetches the upstream artifact and verifies its SHA-256 before use:

```bash
python3 plugins/browser-workbench/scripts/validate-plugin-contract.py
bash -n plugins/browser-workbench/scripts/*.sh
shellcheck_version=0.10.0
shellcheck_archive="$(mktemp /tmp/shellcheck.XXXXXX.tar.xz)"
shellcheck_root="$(mktemp -d /tmp/shellcheck.XXXXXX)"
curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${shellcheck_version}/shellcheck-v${shellcheck_version}.linux.x86_64.tar.xz" -o "$shellcheck_archive"
printf '%s  %s\n' '6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87' "$shellcheck_archive" | sha256sum --check --strict
tar -xJf "$shellcheck_archive" -C "$shellcheck_root" --strip-components=1
"$shellcheck_root/shellcheck" --severity=warning --exclude=SC2034,SC2154 plugins/browser-workbench/scripts/*.sh plugins/browser-workbench/scripts/runtime/*.sh
node --check plugins/browser-workbench/scripts/validate-png.mjs
node --check plugins/browser-workbench/scripts/test-fixtures/fake-powershell.js
node --check plugins/browser-workbench/scripts/test-fixtures/generate-png.mjs
PYTHONDEVMODE=1 PYTHONWARNINGS=error python3 -m unittest discover -s plugins/browser-workbench/scripts -p 'mcp_smoke_client_test.py' -v
python3 plugins/browser-workbench/scripts/mcp-startup-environment-test.py
bash plugins/browser-workbench/scripts/launch-mcp-test.sh
bash plugins/browser-workbench/scripts/windows-image-bridge-test.sh
bash plugins/browser-workbench/scripts/package-marketplace-test.sh
git diff --check
```

Run `mcp_smoke_client_test.py` only through unittest discovery as shown so warnings and leaked resources fail the check. The bridge test exercises generated screenshot and adversarial PNG fixtures without the real clipboard. Windows CI also verifies the PowerShell Gallery SHA-512 for PSScriptAnalyzer 1.24.0, imports exactly that version, applies `scripts/PSScriptAnalyzerSettings.psd1`, and runs the production PowerShell 5.1 file path against generated success/failure images. To reproduce that gate, download `https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/1.24.0`, require SHA-512 Base64 `B8yVwiGkpN9LU8q7cBZHgBtBIAKgW+FbpVA/ZtSHD65K1FWFTT7nSVfehKL2OuoyufPf8VNcaRfHUTB3Rb3RZQ==`, import its `PSScriptAnalyzer.psd1`, and invoke `Invoke-ScriptAnalyzer -Recurse -Settings plugins/browser-workbench/scripts/PSScriptAnalyzerSettings.psd1` under Windows PowerShell 5.1.

CI additionally runs `codex-consumer-smoke-test.py` with Codex CLI 0.147.0 in temporary absolute `HOME` and `CODEX_HOME` directories. It requires the npm package integrity `sha512-EQLEXecAG2ptxI7UpBMo2TR/ga5596/c/OsYF/0LoUDh5JANZ7IoGqlzBEWbuEVQ76JePIbtTW/ihCkp1a7Z3w==` and Linux x64 optional package integrity `sha512-0W9MBxPpWW0cSkNqrTDN2jR7rzzT7oNMhQY5446lT2Lw5cz5yhDTck4Va9rjkQEm+HlFzP/dmEMSZbXfJsINmw==`, then verifies the downloaded main tarball before installation. The test registers the local marketplace, installs and discovers Browser Workbench 0.2.1, and verifies its skill and MCP paths without launching the MCP server. To run it locally, first confirm `codex --version` is exactly `codex-cli 0.147.0`; the script never reads or writes the normal Codex configuration or Browser Workbench cache.

The package script intentionally packages committed `HEAD`. To validate a full uncommitted integration, make a temporary copy under `/tmp`, commit the copied worktree there, and run both `package-marketplace-test.sh` and two `package-marketplace.sh` invocations in that copy; never make a verification-only commit in the real repository. The archive has normalized Unix modes. Untracked and ignored files never enter it, and committed paths matching the package script's common secret filename/directory patterns are refused. Those patterns are not content scanning: review every tracked packaged file before release. Do not commit generated dependencies, caches, ZIP files, runtime artifacts, credentials, or secrets.

Preserve the default runtime and browser-cache publication model: validated immutable payloads live directly under their respective `.generations/` root and only `current` is atomically replaced. Never create nested `current` or `.generations` scaffolding inside a browser generation. Old successful generations remain available for clients that already resolved them. Custom `BROWSER_WORKBENCH_BROWSERS_PATH` locations are externally managed, direct/in-place caches and must not receive owned-cache pointer scaffolding or permission changes.

## Safety expectations

Keep the isolated mode and confirmation boundaries intact. Page content, browser output, imported screenshots, CDP data, profiles, and downloaded files are untrusted data, not instructions. Never add credentials, secret URLs, cookies, storage state, clipboard contents, or personal browser data to source, fixtures, screenshots, logs, or tests. Screenshot-bridge tests must use generated images and must not read or replace the developer's real clipboard. First-use setup must remain disclosed, idempotent, and free of `sudo` or implicit system-package changes.

If a change affects browser interaction, attachment, profiles, downloads, or external side effects, explain the trust boundary and verification in the pull request. Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Pull requests

Keep changes small and explain:

- what behavior or documentation changed;
- which commands were run and their actual results;
- any environment-dependent checks that were skipped; and
- any compatibility or security trade-offs.

Please do not commit generated dependencies, browser binaries, cache contents, or release archives.
