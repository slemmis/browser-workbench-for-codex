# Security policy

Browser Workbench for Codex runs a local Playwright MCP server and includes an explicit Windows screenshot bridge, but browser pages, imported screenshots, accessibility trees, console and network messages, downloaded files, profiles, and CDP responses are untrusted input. The skill's confirmation boundary requires user approval immediately before login, secret entry, form submission, purchases, messages, uploads or downloads, permission changes, destructive edits, or attachment to an existing profile or CDP endpoint.

## Supported versions

The latest public release line is supported. Unreleased development branches are validated before publication but are not release artifacts.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to [michael.parkdahl@gmail.com](mailto:michael.parkdahl@gmail.com) rather than opening a public issue. Include the affected version, operating system or WSL distribution, mode and configuration involved, reproduction steps, and the smallest relevant logs or screenshots after removing credentials, cookies, tokens, private URLs, and personal data.

Do not send secrets or live browser profile data in a report. If the issue involves a third-party dependency, identify the package and version so it can be coordinated with the upstream project.

## Scope

This project does not operate a hosted service or collect telemetry. The setup script downloads dependencies and Chromium from their upstream distribution channels, and browser traffic is determined by the user’s requested target. The screenshot bridge does not watch the clipboard or use the network; it reads a Windows image only on explicit invocation and stores a normalized PNG in a private Linux cache. Keep endpoints credential-free and use isolated mode unless persistence or an existing browser is explicitly required.
