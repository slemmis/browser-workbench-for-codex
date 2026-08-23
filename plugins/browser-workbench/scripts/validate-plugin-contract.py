#!/usr/bin/env python3
"""Validate Browser Workbench's install and packaging contracts with stdlib only."""

from __future__ import annotations

import json
import re
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
REPOSITORY_ROOT = PLUGIN_ROOT.parent.parent
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
MANIFEST_FIELDS = {
    "id", "name", "version", "description", "skills", "apps", "mcpServers",
    "interface", "author", "homepage", "repository", "license", "keywords",
}
INTERFACE_FIELDS = {
    "displayName", "shortDescription", "longDescription", "developerName",
    "category", "capabilities", "websiteURL", "privacyPolicyURL",
    "termsOfServiceURL", "brandColor", "composerIcon", "logo", "logoDark",
    "screenshots", "defaultPrompt", "default_prompt",
}
EXECUTABLE_SCRIPTS = {
    "codex-consumer-smoke-test.py", "doctor.sh", "launch-mcp.sh", "launch-mcp-test.sh", "mcp-smoke-test.sh",
    "mcp-startup-environment-test.py",
    "mcp_smoke_test.py", "mcp_smoke_client_test.py", "mcp_smoke_fake_server_fixture.py",
    "package-marketplace.sh", "package-marketplace-test.sh", "setup.sh",
    "smoke-test.sh", "validate-plugin-contract.py", "windows-image-bridge-test.sh",
    "windows-image-bridge.sh",
}
REQUIRED_PACKAGE_FILES = {
    ".agents/plugins/marketplace.json", "LICENSE", "README.md", "SECURITY.md",
    "plugins/browser-workbench/.codex-plugin/plugin.json",
    "plugins/browser-workbench/.mcp.json",
    "plugins/browser-workbench/scripts/runtime/common.sh",
    "plugins/browser-workbench/scripts/runtime/package.json",
    "plugins/browser-workbench/scripts/runtime/package-lock.json",
    "plugins/browser-workbench/scripts/runtime/validate-graph.mjs",
    "plugins/browser-workbench/scripts/runtime/versions.env",
    "plugins/browser-workbench/scripts/PSScriptAnalyzerSettings.psd1",
    "plugins/browser-workbench/scripts/windows-image-bridge.ps1",
    "plugins/browser-workbench/scripts/windows-image-bridge-native-test.ps1",
    "plugins/browser-workbench/skills/browser-workbench/SKILL.md",
    "plugins/browser-workbench/skills/browser-workbench/agents/openai.yaml",
    "plugins/browser-workbench/skills/browser-workbench/references/modes-and-setup.md",
    "plugins/browser-workbench/skills/browser-workbench/references/safety.md",
} | {f"plugins/browser-workbench/scripts/{name}" for name in EXECUTABLE_SCRIPTS}


def fail(message: str) -> None:
    raise ValueError(message)


def load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{path.relative_to(REPOSITORY_ROOT)}: invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(REPOSITORY_ROOT)}: expected a JSON object")
    return value


def nonempty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{field} must be a non-empty string")
    return value


def relative_path(raw: Any, field: str, base: Path, expected: str) -> Path:
    value = nonempty_string(raw, field).replace("\\", "/").rstrip("/")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"{field} must be a safe relative path")
    if path.as_posix() != expected:
        fail(f"{field} must resolve to {expected!r}")
    target = base / path.as_posix()
    if not target.exists():
        fail(f"{field} points to a missing path")
    return target


def validate_manifest() -> None:
    manifest = load_object(PLUGIN_ROOT / ".codex-plugin" / "plugin.json")
    unknown = set(manifest) - MANIFEST_FIELDS
    if unknown:
        fail(f"plugin.json has unsupported fields: {sorted(unknown)}")
    for field in ("name", "version", "description"):
        nonempty_string(manifest.get(field), f"plugin.json.{field}")
    if "id" in manifest:
        nonempty_string(manifest["id"], "plugin.json.id")
    if manifest["name"] != "browser-workbench":
        fail("plugin.json.name must be 'browser-workbench'")
    if not SEMVER.fullmatch(manifest["version"]):
        fail("plugin.json.version must be strict semver")
    if manifest["version"] != "0.2.1":
        fail("plugin.json.version must be 0.2.1 for this source identity")
    relative_path(manifest.get("skills"), "plugin.json.skills", PLUGIN_ROOT, "skills")
    relative_path(manifest.get("mcpServers"), "plugin.json.mcpServers", PLUGIN_ROOT, ".mcp.json")
    author = manifest.get("author")
    if not isinstance(author, dict) or set(author) - {"name", "email", "url"}:
        fail("plugin.json.author must contain only name, email, and optional url")
    nonempty_string(author.get("name"), "plugin.json.author.name")
    for field in ("email", "url"):
        if field in author:
            nonempty_string(author[field], f"plugin.json.author.{field}")
    for field in ("homepage", "repository", "license"):
        if field in manifest:
            nonempty_string(manifest[field], f"plugin.json.{field}")
    keywords = manifest.get("keywords")
    if keywords is not None and (
        not isinstance(keywords, list)
        or not keywords
        or not all(isinstance(item, str) and item.strip() for item in keywords)
    ):
        fail("plugin.json.keywords must be a non-empty string array")
    interface = manifest.get("interface")
    if not isinstance(interface, dict) or set(interface) - INTERFACE_FIELDS:
        fail("plugin.json.interface contains unsupported fields or is not an object")
    for field in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
        nonempty_string(interface.get(field), f"plugin.json.interface.{field}")
    for field in ("websiteURL", "privacyPolicyURL", "termsOfServiceURL", "brandColor"):
        if field in interface:
            nonempty_string(interface[field], f"plugin.json.interface.{field}")
    if "brandColor" in interface and not re.fullmatch(r"#[0-9A-Fa-f]{6}", interface["brandColor"]):
        fail("plugin.json.interface.brandColor must use #RRGGBB")
    prompts = interface.get("defaultPrompt", interface.get("default_prompt"))
    if not (isinstance(prompts, str) and prompts.strip()) and not (
        isinstance(prompts, list) and prompts and all(isinstance(item, str) and item.strip() for item in prompts)
    ):
        fail("plugin.json.interface.defaultPrompt must be a string or non-empty string array")
    capabilities = interface.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities or not all(
        isinstance(item, str) and item.strip() for item in capabilities
    ):
        fail("plugin.json.interface.capabilities must be a non-empty string array")


def validate_marketplace() -> None:
    marketplace = load_object(REPOSITORY_ROOT / ".agents" / "plugins" / "marketplace.json")
    plugins = marketplace.get("plugins")
    if not isinstance(plugins, list) or len(plugins) != 1 or not isinstance(plugins[0], dict):
        fail("marketplace.json must contain exactly one plugin entry")
    entry = plugins[0]
    source = entry.get("source")
    if entry.get("name") != "browser-workbench" or source != {
        "source": "local", "path": "./plugins/browser-workbench"
    }:
        fail("marketplace plugin name/source path does not reference the bundled plugin")


def validate_mcp() -> None:
    payload = load_object(PLUGIN_ROOT / ".mcp.json")
    if set(payload) != {"mcpServers"} or not isinstance(payload["mcpServers"], dict):
        fail(".mcp.json must contain only an mcpServers object")
    if set(payload["mcpServers"]) != {"browser-workbench"}:
        fail(".mcp.json must define exactly the browser-workbench server")
    server = payload["mcpServers"]["browser-workbench"]
    if server != {
        "command": "bash",
        "args": ["./scripts/launch-mcp.sh"],
        "cwd": ".",
        "env": {
            "BASH_ENV": "", "BASHOPTS": "", "BASH_XTRACEFD": "",
            "ENV": "", "NODE_OPTIONS": "", "SHELLOPTS": "",
        },
    }:
        fail(".mcp.json server contract or startup-environment sanitization changed")


def quoted_yaml_value(text: str, key: str) -> str:
    match = re.search(rf"(?m)^  {re.escape(key)}: \"([^\"\r\n]+)\"$", text)
    if not match:
        fail(f"openai.yaml interface.{key} must be a quoted non-empty string")
    return match.group(1)


def validate_skill() -> None:
    skill_root = PLUGIN_ROOT / "skills" / "browser-workbench"
    skill = (skill_root / "SKILL.md").read_text(encoding="utf-8")
    frontmatter = re.match(r"\A---\n(.*?)\n---\n", skill, re.DOTALL)
    if not frontmatter:
        fail("SKILL.md must have closed YAML frontmatter")
    if not re.search(r"(?m)^name: browser-workbench$", frontmatter.group(1)):
        fail("SKILL.md frontmatter must name browser-workbench")
    if not re.search(r"(?m)^description: \S", frontmatter.group(1)):
        fail("SKILL.md frontmatter must include a description")

    agent = (skill_root / "agents" / "openai.yaml").read_text(encoding="utf-8")
    interface_match = re.match(r"\Ainterface:\n(?P<body>(?:  [a-z_]+: \"[^\"\r\n]+\"\n)+)\n", agent)
    if not interface_match:
        fail("openai.yaml must start with a quoted interface mapping")
    interface_keys = re.findall(r"(?m)^  ([a-z_]+):", interface_match.group("body"))
    if interface_keys != ["display_name", "short_description", "brand_color", "default_prompt"]:
        fail("openai.yaml interface fields changed from the supported contract")
    for key in ("display_name", "short_description", "brand_color", "default_prompt"):
        quoted_yaml_value(agent, key)
    prompt = quoted_yaml_value(agent, "default_prompt")
    if "$browser-workbench" not in prompt:
        fail("openai.yaml default_prompt must mention $browser-workbench")
    dependency_pattern = re.compile(
        r'(?ms)^dependencies:\n  tools:\n(?P<items>(?:    - type: "(?:mcp|cli)"\n'
        r'      value: "[^"\r\n]+"\n      description: "[^"\r\n]+"\n?)+)\Z'
    )
    match = dependency_pattern.search(agent)
    if not match:
        fail("openai.yaml dependencies must use the supported tools entry shape")
    pairs = re.findall(r'    - type: "(mcp|cli)"\n      value: "([^"\r\n]+)"', match.group("items"))
    if pairs != [("mcp", "browser-workbench"), ("cli", "node"), ("cli", "npm")]:
        fail("openai.yaml dependencies must declare browser-workbench MCP, node, and npm only")


def validate_package_files_and_modes() -> None:
    missing = sorted(path for path in REQUIRED_PACKAGE_FILES if not (REPOSITORY_ROOT / path).is_file())
    if missing:
        fail(f"required package files are missing: {missing}")
    scripts = PLUGIN_ROOT / "scripts"
    for name in sorted(EXECUTABLE_SCRIPTS):
        mode = stat.S_IMODE((scripts / name).stat().st_mode)
        if mode & 0o111 == 0:
            fail(f"scripts/{name} must be executable")
    for name in ("windows-image-bridge.ps1", "windows-image-bridge-native-test.ps1"):
        if stat.S_IMODE((scripts / name).stat().st_mode) & 0o111:
            fail(f"scripts/{name} must be packaged as data, not executable")


def validate_runtime_lock() -> None:
    package = load_object(SCRIPT_DIR / "runtime" / "package.json")
    lock = load_object(SCRIPT_DIR / "runtime" / "package-lock.json")
    if package != {
        "name": "browser-workbench-runtime",
        "private": True,
        "dependencies": {"@playwright/mcp": "0.0.79"},
    }:
        fail("runtime package.json must contain only the exact MCP dependency pin")
    if set(lock) != {"name", "lockfileVersion", "requires", "packages"}:
        fail("runtime lockfile has an unexpected top-level key set")
    if lock.get("name") != "browser-workbench-runtime" or lock.get("lockfileVersion") != 3 or lock.get("requires") is not True:
        fail("runtime lockfile header changed")
    packages = lock.get("packages")
    expected_keys = {
        "", "node_modules/@playwright/mcp", "node_modules/fsevents",
        "node_modules/playwright", "node_modules/playwright-core",
    }
    if not isinstance(packages, dict) or set(packages) != expected_keys:
        fail("runtime lockfile package key set changed")
    if packages[""] != {
        "name": "browser-workbench-runtime",
        "dependencies": {"@playwright/mcp": "0.0.79"},
    }:
        fail("runtime lockfile root dependency edge changed")
    expected_artifacts = {
        "node_modules/@playwright/mcp": (
            "0.0.79",
            "https://registry.npmjs.org/@playwright/mcp/-/mcp-0.0.79.tgz",
            "sha512-VpqD4a3vFyGQMY9sh3UJiO6wjcurggkljKfAyCHL0QWGY5m6Ehr3MNsAAHPDHO//n13g0PCjpHatAOiulrqdZQ==",
            {"playwright": "1.63.0-alpha-2026-08-05", "playwright-core": "1.63.0-alpha-2026-08-05"},
            None,
        ),
        "node_modules/fsevents": (
            "2.3.2",
            "https://registry.npmjs.org/fsevents/-/fsevents-2.3.2.tgz",
            "sha512-xiqMQR4xAeHTuB9uWm+fFRcIOgKBMiOBP+eXiyT7jsgVCq1bkVygt00oASowB7EdtpOHaaPgKt812P9ab+DDKA==",
            None,
            None,
        ),
        "node_modules/playwright": (
            "1.63.0-alpha-2026-08-05",
            "https://registry.npmjs.org/playwright/-/playwright-1.63.0-alpha-2026-08-05.tgz",
            "sha512-zbGZUK+JYkoDV3cUgfvh2czTBJL34Gmz5gHVI25xiIpvYSR17Q1M7TS8hnwECUe+IkKaeXbKrSyJTyogm2DVWw==",
            {"playwright-core": "1.63.0-alpha-2026-08-05"},
            {"fsevents": "2.3.2"},
        ),
        "node_modules/playwright-core": (
            "1.63.0-alpha-2026-08-05",
            "https://registry.npmjs.org/playwright-core/-/playwright-core-1.63.0-alpha-2026-08-05.tgz",
            "sha512-YussvUybTfBtyYbGXWh43f+5kNP03wg98M6mu4DphYET7PSbNVajsdLGjWE1xrsjqOw32i2wFlRP7U5mcOpMZg==",
            None,
            None,
        ),
    }
    for name, (version, resolved, integrity, dependencies, optional_dependencies) in expected_artifacts.items():
        entry = packages[name]
        if not isinstance(entry, dict):
            fail(f"runtime lock entry {name!r} must be an object")
        if (entry.get("version"), entry.get("resolved"), entry.get("integrity")) != (version, resolved, integrity):
            fail(f"runtime lock artifact identity changed for {name!r}")
        if entry.get("dependencies") != dependencies:
            fail(f"runtime lock dependency edges changed for {name!r}")
        if entry.get("optionalDependencies") != optional_dependencies:
            fail(f"runtime lock optional dependency edges changed for {name!r}")
    fsevents = packages["node_modules/fsevents"]
    if fsevents.get("optional") is not True or fsevents.get("os") != ["darwin"]:
        fail("runtime lock fsevents optional/platform contract changed")


def main() -> int:
    try:
        validate_manifest()
        validate_marketplace()
        validate_mcp()
        validate_skill()
        validate_package_files_and_modes()
        validate_runtime_lock()
    except (OSError, ValueError) as error:
        print(f"browser-workbench contract validation failed: {error}", file=sys.stderr)
        return 1
    print("Browser Workbench plugin, skill, MCP, runtime, and package contracts passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
