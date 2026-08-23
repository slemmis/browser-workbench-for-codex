#!/usr/bin/env python3
"""Exercise the production MCP command across the pre-Bash environment boundary."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent


def main() -> int:
    configuration = json.loads((PLUGIN_ROOT / ".mcp.json").read_text(encoding="utf-8"))
    server = configuration["mcpServers"]["browser-workbench"]
    command = [server["command"], *server["args"]]

    with tempfile.TemporaryDirectory(prefix="browser-workbench-mcp-startup-") as temporary:
        temporary_root = Path(temporary)
        startup_file = temporary_root / "hostile-bash-env.sh"
        startup_file.write_text(
            "printf 'BASH_ENV_RAN\\n'\nexport STARTUP_FILE_MUTATED=1\n",
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(temporary_root / "home"),
                "XDG_CACHE_HOME": str(temporary_root / "cache"),
                "BROWSER_WORKBENCH_DRY_RUN": "1",
                "BASH_ENV": str(startup_file),
                "ENV": str(startup_file),
                "NODE_OPTIONS": "--definitely-invalid-option",
                "SHELLOPTS": "xtrace",
                "BASHOPTS": "extdebug",
                "BASH_XTRACEFD": "1",
                "HTTPS_PROXY": "http://proxy.example.invalid:8080",
                "DISPLAY": ":77",
            }
        )
        environment.update(server["env"])

        result = subprocess.run(
            command,
            cwd=PLUGIN_ROOT / server["cwd"],
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(f"production MCP command failed: {result.stderr!r}")
        if result.stderr:
            raise AssertionError(f"pre-launch environment polluted stderr: {result.stderr!r}")
        if not result.stdout.startswith("browser-workbench dry run:"):
            raise AssertionError(f"unexpected launcher stdout: {result.stdout!r}")
        for contamination in ("+ ", "BASH_ENV_RAN", "STARTUP_FILE_MUTATED"):
            if contamination in result.stdout:
                raise AssertionError(f"pre-Bash contamination reached stdout: {result.stdout!r}")
        if (temporary_root / "cache").exists():
            raise AssertionError("dry-run startup test mutated the cache")
        for preserved in ("HTTPS_PROXY", "DISPLAY"):
            if preserved in server["env"]:
                raise AssertionError(f"MCP overlay unexpectedly overrides {preserved}")

    print("Browser Workbench hostile MCP startup-environment test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
