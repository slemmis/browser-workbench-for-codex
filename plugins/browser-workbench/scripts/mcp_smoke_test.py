#!/usr/bin/env python3
"""Exercise the bundled MCP server through real browser tools."""

from __future__ import annotations

import json
import os
import selectors
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote


EXPECTED_TEXT = "Browser Workbench for Codex MCP smoke"


class McpClient:
    def __init__(self, launcher: Path, plugin_root: Path) -> None:
        environment = os.environ.copy()
        environment.update(
            {
                "BROWSER_WORKBENCH_MODE": "isolated",
                "BROWSER_WORKBENCH_HEADED": "0",
                "BROWSER_WORKBENCH_DRY_RUN": "0",
            }
        )
        for key in (
            "BROWSER_WORKBENCH_BROWSER",
            "BROWSER_WORKBENCH_CAPS",
            "BROWSER_WORKBENCH_CDP_ENDPOINT",
            "BROWSER_WORKBENCH_USER_DATA_DIR",
            "BROWSER_WORKBENCH_RUNTIME_DIR",
            "BROWSER_WORKBENCH_BROWSERS_PATH",
        ):
            environment.pop(key, None)

        self.process = subprocess.Popen(
            ["bash", str(launcher)],
            cwd=str(plugin_root),
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.next_id = 1

    def send(self, message: dict[str, object]) -> None:
        if self.process.stdin is None:
            raise RuntimeError("MCP stdin is closed")
        self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

    def receive(self, timeout: float = 30.0) -> dict[str, object]:
        events = self.selector.select(timeout)
        if not events:
            raise TimeoutError("timed out waiting for an MCP response")
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"MCP exited before responding (code {self.process.poll()})")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"MCP emitted non-JSON stdout: {line!r}") from error
        if not isinstance(message, dict):
            raise RuntimeError(f"MCP emitted a non-object message: {message!r}")
        return message

    def request(self, method: str, params: dict[str, object]) -> dict[str, object]:
        request_id = self.next_id
        self.next_id += 1
        self.send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            }
        )
        while True:
            message = self.receive()
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError(f"MCP {method} failed: {message['error']}")
            return message

    def notify(self, method: str, params: dict[str, object]) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self) -> str:
        try:
            if self.process.stdin is not None:
                self.process.stdin.close()
        finally:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
            self.selector.close()
        assert self.process.stderr is not None
        return self.process.stderr.read()


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    plugin_root = script_dir.parent
    launcher = script_dir / "launch-mcp.sh"
    client = McpClient(launcher, plugin_root)
    failure: Exception | None = None
    try:
        client.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "browser-workbench-mcp-smoke", "version": "1"},
            },
        )
        client.notify("notifications/initialized", {})

        page = quote(
            f"<main><h1>{EXPECTED_TEXT}</h1><p>Rendered MCP content OK</p></main>",
            safe="",
        )
        navigation = client.request(
            "tools/call",
            {
                "name": "browser_navigate",
                "arguments": {"url": f"data:text/html,{page}"},
            },
        )
        if navigation.get("result", {}).get("isError"):
            raise RuntimeError(f"browser_navigate returned an error: {navigation}")

        snapshot = client.request(
            "tools/call",
            {"name": "browser_snapshot", "arguments": {}},
        )
        if snapshot.get("result", {}).get("isError"):
            raise RuntimeError(f"browser_snapshot returned an error: {snapshot}")
        if EXPECTED_TEXT not in json.dumps(snapshot, ensure_ascii=False):
            raise RuntimeError("browser_snapshot did not contain the expected rendered text")

        closed = client.request("tools/call", {"name": "browser_close", "arguments": {}})
        if closed.get("result", {}).get("isError"):
            raise RuntimeError(f"browser_close returned an error: {closed}")
    except Exception as error:  # noqa: BLE001 - report the concrete protocol failure.
        failure = error
    finally:
        stderr = client.close()

    if failure is not None:
        print(f"browser-workbench MCP smoke test failed: {failure}", file=sys.stderr)
        if stderr.strip():
            print(stderr, file=sys.stderr, end="")
        return 1
    if stderr.strip():
        print("browser-workbench MCP smoke test failed: launcher wrote to stderr", file=sys.stderr)
        print(stderr, file=sys.stderr, end="")
        return 1
    print("Browser MCP smoke test passed: initialize, browser_navigate, browser_snapshot, and browser_close")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
