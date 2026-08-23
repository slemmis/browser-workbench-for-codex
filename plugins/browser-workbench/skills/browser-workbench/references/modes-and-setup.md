# Modes and setup

Run these commands from the plugin directory (`plugins/browser-workbench`):

```bash
bash scripts/setup.sh
bash scripts/doctor.sh
bash scripts/smoke-test.sh
bash scripts/mcp-smoke-test.sh
```

`setup.sh` requires Node.js 20 or newer, `npm`, and `npx`. It installs the pinned `@playwright/mcp@0.0.79` package into `${XDG_CACHE_HOME:-$HOME/.cache}/browser-workbench/runtime` by default, with the Chromium browser cache at the sibling `browsers/` path. Override either location with `BROWSER_WORKBENCH_RUNTIME_DIR` or `BROWSER_WORKBENCH_BROWSERS_PATH`. The package metadata declares the exact compatible Playwright version `1.63.0-alpha-2026-08-05`; setup reads that declaration and uses the installed Playwright CLI to install Chromium. It does not invoke `sudo` or install Linux system packages.

`mcp-smoke-test.sh` is an optional verification helper and additionally requires `python3`; normal plugin operation does not.

The launcher accepts only these wrapper variables:

| Variable | Values | Default |
| --- | --- | --- |
| `BROWSER_WORKBENCH_MODE` | `isolated`, `persistent`, `extension`, `cdp` | `isolated` |
| `BROWSER_WORKBENCH_HEADED` | `0`, `1`, `false`, `true` | `0` |
| `BROWSER_WORKBENCH_BROWSER` | `chrome`, `firefox`, `webkit`, `msedge` | pinned local Chromium executable |
| `BROWSER_WORKBENCH_CAPS` | comma-separated `vision`, `pdf`, `devtools` | none |
| `BROWSER_WORKBENCH_USER_DATA_DIR` | profile path, persistent mode only | `$CACHE_ROOT/profiles/default` in `persistent` |
| `BROWSER_WORKBENCH_CDP_ENDPOINT` | credential-free `http(s)://` or `ws(s)://` endpoint | required for `cdp` |
| `BROWSER_WORKBENCH_TMPDIR` | Linux temp directory for MCP browser sockets | user cache `tmp/` |
| `BROWSER_WORKBENCH_OUTPUT_DIR` | MCP snapshots and visual evidence directory | user cache `output/` |

`isolated` and `persistent` launch headless by default; when no browser channel is selected, the launcher resolves `chromium.executablePath()` from the installed pinned Playwright package, verifies the executable, and passes it explicitly. `persistent` uses `$CACHE_ROOT/profiles/default` unless `BROWSER_WORKBENCH_USER_DATA_DIR` is supplied. A profile path is rejected in all other modes. The launcher also uses a per-user Linux temp directory for MCP browser sockets, avoiding WSL failures caused by Windows-mounted temp paths; override it only with a Linux-accessible path. Set `BROWSER_WORKBENCH_HEADED=1` for a visible local browser. `extension` attaches to a running Chrome/Edge browser, and `cdp` attaches to the explicit endpoint without launching a new browser. CDP endpoints containing credentials or targeting `0.0.0.0` are rejected. Do not put credentials in an endpoint or profile path. The launcher never prints the endpoint during normal MCP operation.

`smoke-test.sh` opens a `data:` page in a real headless Chromium, verifies rendered text, and writes a screenshot under the user cache. `mcp-smoke-test.sh` starts the bundled MCP launcher, initializes MCP, navigates through `browser_navigate`, requests `browser_snapshot`, verifies rendered text, and closes the browser. MCP snapshots and other evidence go to the user-cache `output/` directory by default, not the marketplace source. If launch fails on Linux, install the required system libraries for your distribution deliberately (for example, using Playwright's documented `--with-deps` flow) and rerun the smoke tests; this bundle never invokes `sudo` implicitly. Extension and CDP modes are validated here only through deterministic launcher dry runs; live attachment, especially from Windows into WSL, remains environment-dependent.

For upstream option semantics, see the [Playwright MCP configuration](https://github.com/microsoft/playwright-mcp#configuration) and [Playwright browser installation](https://playwright.dev/docs/browsers) documentation.
