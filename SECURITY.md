# Security policy

Browser Workbench for Codex runs a local Playwright MCP server, but browser pages, accessibility trees, console and network messages, downloaded files, profiles, and CDP responses are untrusted input. The skill's confirmation boundary requires user approval immediately before login, secret entry, form submission, purchases, messages, uploads or downloads, permission changes, destructive edits, or attachment to an existing profile or CDP endpoint.

## Supported versions

The `0.1.x` release line is the currently supported public release line.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to [michael.parkdahl@gmail.com](mailto:michael.parkdahl@gmail.com) rather than opening a public issue. Include the affected version, operating system or WSL distribution, mode and configuration involved, reproduction steps, and the smallest relevant logs or screenshots after removing credentials, cookies, tokens, private URLs, and personal data.

Do not send secrets or live browser profile data in a report. If the issue involves a third-party dependency, identify the package and version so it can be coordinated with the upstream project.

## Scope

This project does not operate a hosted service or collect telemetry. The setup script downloads dependencies and Chromium from their upstream distribution channels, and browser traffic is determined by the user’s requested target. Keep endpoints credential-free and use isolated mode unless persistence or an existing browser is explicitly required.
