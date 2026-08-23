# Modes and setup

Normal marketplace users do not need a checkout or a separate setup step. On first MCP use, `scripts/launch-mcp.sh` reports the one-time preparation on stderr, installs the committed lockfile with `npm ci`, and downloads pinned Chromium into the user cache. Network access is required for that first use. The automatic setup never invokes `sudo` or installs Linux system libraries; if Chromium reports missing libraries, install the distribution packages deliberately and start a new task.

Contributors can run these commands from the plugin directory (`plugins/browser-workbench`):

```bash
bash scripts/setup.sh
bash scripts/doctor.sh
bash scripts/smoke-test.sh
bash scripts/mcp-smoke-test.sh
bash scripts/windows-image-bridge-test.sh
```

First use and `setup.sh` require Node.js 20 or newer, `npm`, and an absolute Linux `HOME`; `npx` is not used. A relative `XDG_CACHE_HOME` is ignored. `npm ci` installs the exact committed graph—`@playwright/mcp@0.0.79`, Playwright and Playwright Core `1.63.0-alpha-2026-08-05`, and the lockfile's platform-applicable optional dependency—under `${XDG_CACHE_HOME:-$HOME/.cache}/browser-workbench/runtime` by default, with Chromium under the sibling `browsers/` root. Both owned roots store immutable payloads below `.generations/` and atomically publish a `current` symlink only after validation. Launch holds the setup lock while resolving both pointers and binds `PLAYWRIGHT_BROWSERS_PATH` plus the executable to that immutable browser generation, preventing a later setup from moving an active client underneath itself.

Old successful runtime and browser generations are deliberately retained so delayed or relaunched clients can keep using the exact paths they resolved. There is no automatic generation garbage collection, so upgrades and repairs can increase cache use. Do not manually remove individual generations while any Browser Workbench process may be running; after uninstalling, stop clients and review the whole cache before removing it.

Setup migrates a valid pre-generation flat owned cache under the same lock: it copies usable content into new immutable generations and publishes `current`, while leaving the flat files untouched for already-running clients. New launches require the generated pointers after migration. Remove legacy flat content only after every client started before migration has stopped.

`BROWSER_WORKBENCH_RUNTIME_DIR` and `BROWSER_WORKBENCH_BROWSERS_PATH` override the respective locations. A custom browser path is externally managed and updated directly in place. Setup does not create `current`/`.generations` scaffolding inside it, change its permissions, or provide the owned cache's immutable handoff, so callers must coordinate updates and cleanup themselves. In particular, do not point it at a broad/shared directory or update it while clients are using it.

`mcp-smoke-test.sh` is an optional verification helper and additionally requires `python3`; normal plugin operation does not.

## Windows screenshot import

The screenshot bridge is separate from the Playwright MCP transport and remains dormant until explicitly invoked. On WSL with inbox Windows PowerShell 5.1 available:

```bash
bash scripts/windows-image-bridge.sh doctor
bash scripts/windows-image-bridge.sh clipboard
bash scripts/windows-image-bridge.sh file 'C:\Users\me\Pictures\screenshot.png'
```

`doctor` and `--dry-run` do not read the clipboard. Clipboard mode accepts only an actual image. File mode accepts only an absolute local Windows drive path and uses literal-path semantics; it refuses network, device, reparse-point, alternate-data-stream, missing, oversized, unsupported, or malformed sources. Both modes normalize the image to a bounded PNG and return JSON containing its private Linux cache path and dimensions. WebP is explicitly unsupported by the inbox Windows PowerShell 5.1/System.Drawing path. Hermetic bridge tests use a generated PowerShell seam and deterministic PNG fixtures, including malformed chunks, CRC/zlib/order/filter failures, bounded decompression, dimensions, list/cleanup, timeouts, and concurrency. Windows CI separately parses and runs the production PowerShell 5.1 file path against generated success/failure images; neither gate reads the real clipboard. The real-browser smoke uses generated page content and validates its screenshot output.

Use `list` to enumerate valid bridge-managed images. Cleanup is confined to regular, normalized files directly inside the bridge cache and requires either `cleanup --older-than-days N` or `cleanup --all`; add `--dry-run` to preview. The bridge cache defaults to `${XDG_CACHE_HOME:-$HOME/.cache}/browser-workbench/windows-images` with `0700` directory and `0600` file permissions.

The launcher accepts only these wrapper variables:

| Variable | Values | Default |
| --- | --- | --- |
| `BROWSER_WORKBENCH_MODE` | `isolated`, `persistent`, `extension`, `cdp` | `isolated` |
| `BROWSER_WORKBENCH_HEADED` | `0`, `1`, `false`, `true` | `0` |
| `BROWSER_WORKBENCH_BROWSER` | `chrome`, `msedge`, or unset | pinned local Chromium executable |
| `BROWSER_WORKBENCH_CAPS` | comma-separated `vision`, `pdf`, `devtools` | none |
| `BROWSER_WORKBENCH_USER_DATA_DIR` | profile path, persistent mode only | `$CACHE_ROOT/profiles/default` in `persistent` |
| `BROWSER_WORKBENCH_CDP_ENDPOINT` | credential-free `http(s)://` or `ws(s)://` endpoint | required for `cdp` |
| `BROWSER_WORKBENCH_TMPDIR` | Linux temp directory for MCP browser sockets | user cache `tmp/` |
| `BROWSER_WORKBENCH_OUTPUT_DIR` | MCP snapshots and visual evidence directory | user cache `output/` |
| `BROWSER_WORKBENCH_OUTPUT_MAX_SIZE` | positive byte limit up to 10 GiB | `104857600` (100 MiB) |

`isolated` and `persistent` launch headless by default; when no browser channel is selected, the launcher verifies and explicitly selects the pinned Chromium executable. Only installed Linux `chrome` and `msedge` channels can be selected; Firefox and WebKit are not provisioned. `persistent` uses `$CACHE_ROOT/profiles/default` unless `BROWSER_WORKBENCH_USER_DATA_DIR` is supplied. A profile path is rejected in all other modes. The launcher uses a private per-user Linux temp directory for browser sockets and a private output directory with a 100 MiB default MCP output quota. Override those only with Linux-accessible paths whose permissions you have reviewed. Set `BROWSER_WORKBENCH_HEADED=1` for a visible local browser. `extension` attaches to a running Chrome/Edge browser, and `cdp` attaches to the explicit endpoint without launching a new browser. CDP endpoints containing credentials or targeting `0.0.0.0` are rejected. Do not put credentials in an endpoint or profile path. The launcher never prints the endpoint during normal MCP operation.

The plugin MCP entry clears inherited `BASH_ENV`, `ENV`, `NODE_OPTIONS`, `SHELLOPTS`, `BASHOPTS`, and `BASH_XTRACEFD` before Bash starts, preventing startup-file, Node preload, and pre-launch trace-output injection. The launcher then clears Playwright and Node debug overrides. Proxy variables and `DISPLAY`/`WAYLAND_DISPLAY` remain inherited so network and Linux/WSL graphics configuration continue to work.

`smoke-test.sh` opens a generated local page in a real headless Chromium, verifies rendered text, and writes a screenshot under the user cache. `mcp-smoke-test.sh` starts the bundled MCP launcher, initializes MCP, navigates to generated content, requests `browser_snapshot`, verifies rendered text, and closes the browser. MCP snapshots and other evidence go to the user-cache `output/` directory by default, not the marketplace source. If launch fails on Linux, install the required system libraries for your distribution deliberately (for example, using Playwright's documented `--with-deps` flow) and rerun the smoke tests; this bundle never invokes `sudo` implicitly. Extension and CDP modes have deterministic launcher coverage only; live attachment, especially from Windows into WSL, remains environment-dependent.

For upstream option semantics, see the [Playwright MCP configuration](https://github.com/microsoft/playwright-mcp#configuration) and [Playwright browser installation](https://playwright.dev/docs/browsers) documentation.
