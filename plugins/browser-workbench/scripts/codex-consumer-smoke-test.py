#!/usr/bin/env python3
"""Install the plugin with a pinned Codex CLI in a fully isolated home."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


CODEX_VERSION = "0.147.0"
SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
REPOSITORY_ROOT = PLUGIN_ROOT.parent.parent


def run_codex(codex: str, environment: dict[str, str], *arguments: str) -> dict[str, object]:
    result = subprocess.run(
        [codex, *arguments, "--json"],
        cwd=REPOSITORY_ROOT,
        env=environment,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"codex {' '.join(arguments)} failed ({result.returncode}): {result.stderr.strip()}"
        )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"Codex returned invalid JSON: {result.stdout!r}") from error
    if not isinstance(value, dict):
        raise AssertionError("Codex JSON output must be an object")
    return value


def main() -> int:
    codex = os.environ.get("BROWSER_WORKBENCH_CODEX_BIN") or shutil.which("codex")
    if not codex:
        raise AssertionError("codex is required")
    version = subprocess.run(
        [codex, "--version"], text=True, capture_output=True, timeout=10, check=True
    ).stdout.strip()
    if re.fullmatch(rf"codex-cli {re.escape(CODEX_VERSION)}", version) is None:
        raise AssertionError(f"expected codex-cli {CODEX_VERSION}, found {version!r}")

    with tempfile.TemporaryDirectory(prefix="browser-workbench-codex-consumer-") as temporary:
        root = Path(temporary).resolve()
        home = root / "home"
        codex_home = root / "codex-home"
        home.mkdir(mode=0o700)
        codex_home.mkdir(mode=0o700)
        environment = os.environ.copy()
        environment.update({"HOME": str(home), "CODEX_HOME": str(codex_home)})

        added = run_codex(
            codex, environment, "plugin", "marketplace", "add", str(REPOSITORY_ROOT)
        )
        if added.get("marketplaceName") != "browser-workbench":
            raise AssertionError(f"unexpected marketplace result: {added}")
        if Path(str(added.get("installedRoot"))).resolve() != REPOSITORY_ROOT:
            raise AssertionError(f"marketplace resolved the wrong repository: {added}")

        available = run_codex(codex, environment, "plugin", "list", "--available")
        entries = available.get("available")
        if not isinstance(entries, list):
            raise AssertionError(f"available plugin list is malformed: {available}")
        candidate = next(
            (item for item in entries if isinstance(item, dict) and item.get("pluginId") == "browser-workbench@browser-workbench"),
            None,
        )
        if candidate is None or candidate.get("version") != "0.2.1":
            raise AssertionError(f"Browser Workbench 0.2.1 was not discovered: {available}")

        installed = run_codex(
            codex, environment, "plugin", "add", "browser-workbench@browser-workbench"
        )
        if installed.get("version") != "0.2.1":
            raise AssertionError(f"unexpected installed version: {installed}")
        installed_path = Path(str(installed.get("installedPath"))).resolve()
        if not installed_path.is_relative_to((codex_home / "plugins" / "cache").resolve()):
            raise AssertionError(f"plugin escaped isolated CODEX_HOME: {installed_path}")

        manifest = json.loads(
            (installed_path / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
        mcp = json.loads((installed_path / ".mcp.json").read_text(encoding="utf-8"))
        if manifest.get("version") != "0.2.1" or manifest.get("skills") != "./skills/":
            raise AssertionError("installed manifest identity or skill discovery path changed")
        if manifest.get("mcpServers") != "./.mcp.json":
            raise AssertionError("installed manifest MCP discovery path changed")
        if set(mcp.get("mcpServers", {})) != {"browser-workbench"}:
            raise AssertionError("installed MCP server was not discoverable")
        for relative in (
            "skills/browser-workbench/SKILL.md",
            "skills/browser-workbench/agents/openai.yaml",
            "scripts/launch-mcp.sh",
        ):
            if not (installed_path / relative).is_file():
                raise AssertionError(f"installed plugin is missing {relative}")

        listed = run_codex(codex, environment, "plugin", "list")
        installed_entries = listed.get("installed")
        if not isinstance(installed_entries, list) or not any(
            isinstance(item, dict)
            and item.get("pluginId") == "browser-workbench@browser-workbench"
            and item.get("version") == "0.2.1"
            and item.get("enabled") is True
            for item in installed_entries
        ):
            raise AssertionError(f"installed plugin was not enabled/discovered: {listed}")
        if (codex_home / "browser-workbench").exists() or (home / ".cache" / "browser-workbench").exists():
            raise AssertionError("consumer discovery unexpectedly launched the MCP runtime")

    print(f"Browser Workbench Codex consumer smoke passed with codex-cli {CODEX_VERSION}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
