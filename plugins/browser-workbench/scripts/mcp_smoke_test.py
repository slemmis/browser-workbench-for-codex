#!/usr/bin/env python3
"""Exercise the bundled MCP server through real browser tools."""

from __future__ import annotations

import json
import os
import queue
import select
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import quote


EXPECTED_TEXT = "Browser Workbench for Codex MCP smoke"
_MAX_MESSAGE_BYTES = 256 * 1024
_MAX_QUEUED_MESSAGES = 128
_STDERR_TAIL_BYTES = 64 * 1024
_READ_SIZE = 64 * 1024


class McpClient:
    def __init__(
        self,
        launcher: Path,
        plugin_root: Path,
        *,
        shutdown_timeouts: tuple[float, float, float] = (10.0, 5.0, 5.0),
    ) -> None:
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
        ):
            environment.pop(key, None)
        self.process = subprocess.Popen(
            ["bash", str(launcher)],
            cwd=str(plugin_root),
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self._stdin_fd = self.process.stdin.fileno()
        os.set_blocking(self._stdin_fd, False)
        self._messages: queue.Queue[bytes] = queue.Queue(maxsize=_MAX_QUEUED_MESSAGES)
        self._stdout_eof = threading.Event()
        self._stdout_error: str | None = None
        self._stdout_error_lock = threading.Lock()
        self._stderr_tail = bytearray()
        self._stderr_lock = threading.Lock()
        self._shutdown_timeouts = shutdown_timeouts
        self._closed = False
        self._stdout_thread = threading.Thread(
            target=self._read_stdout,
            name="mcp-smoke-stdout",
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._read_stderr,
            name="mcp-smoke-stderr",
            daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread.start()
        self.next_id = 1

    def _set_stdout_error(self, message: str) -> None:
        with self._stdout_error_lock:
            if self._stdout_error is None:
                self._stdout_error = message

    def _queue_line(self, line: bytes) -> None:
        if len(line) > _MAX_MESSAGE_BYTES:
            self._set_stdout_error(
                f"MCP stdout message exceeded {_MAX_MESSAGE_BYTES} bytes"
            )
            return
        try:
            self._messages.put_nowait(line)
        except queue.Full:
            self._set_stdout_error(
                f"MCP produced more than {_MAX_QUEUED_MESSAGES} queued messages"
            )

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        buffered = bytearray()
        discarding_oversized_line = False
        try:
            while True:
                chunk = os.read(self.process.stdout.fileno(), _READ_SIZE)
                if not chunk:
                    break
                if discarding_oversized_line:
                    newline = chunk.find(b"\n")
                    if newline < 0:
                        continue
                    chunk = chunk[newline + 1 :]
                    discarding_oversized_line = False
                buffered.extend(chunk)
                while True:
                    newline = buffered.find(b"\n")
                    if newline < 0:
                        break
                    line = bytes(buffered[: newline + 1])
                    del buffered[: newline + 1]
                    self._queue_line(line)
                if len(buffered) > _MAX_MESSAGE_BYTES:
                    self._set_stdout_error(
                        f"MCP stdout message exceeded {_MAX_MESSAGE_BYTES} bytes"
                    )
                    buffered.clear()
                    discarding_oversized_line = True
            if buffered and not discarding_oversized_line:
                self._queue_line(bytes(buffered))
        except OSError as error:
            if not self._closed:
                self._set_stdout_error(f"failed reading MCP stdout: {error}")
        finally:
            self._stdout_eof.set()

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        try:
            while True:
                chunk = os.read(self.process.stderr.fileno(), _READ_SIZE)
                if not chunk:
                    return
                with self._stderr_lock:
                    self._stderr_tail.extend(chunk)
                    excess = len(self._stderr_tail) - _STDERR_TAIL_BYTES
                    if excess > 0:
                        del self._stderr_tail[:excess]
        except OSError:
            return

    def stderr_tail(self) -> str:
        with self._stderr_lock:
            diagnostic = bytes(self._stderr_tail)
        return diagnostic.decode("utf-8", errors="replace")

    def send(
        self,
        message: dict[str, object],
        *,
        timeout: float = 30.0,
        deadline: float | None = None,
    ) -> None:
        if (
            self._closed
            or self.process.stdin is None
            or self.process.stdin.closed
        ):
            raise RuntimeError("MCP stdin is closed")
        if deadline is None:
            deadline = time.monotonic() + timeout
        payload = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        try:
            view = memoryview(payload)
            while view:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    diagnostic = self.stderr_tail().strip()
                    detail = f"; stderr tail: {diagnostic}" if diagnostic else ""
                    raise TimeoutError(f"timed out writing MCP request{detail}")
                try:
                    _, writable, _ = select.select(
                        [], [self._stdin_fd], [], remaining
                    )
                except InterruptedError:
                    continue
                if not writable:
                    diagnostic = self.stderr_tail().strip()
                    detail = f"; stderr tail: {diagnostic}" if diagnostic else ""
                    raise TimeoutError(f"timed out writing MCP request{detail}")
                try:
                    written = os.write(self._stdin_fd, view)
                except (BlockingIOError, InterruptedError):
                    continue
                if written == 0:
                    raise BrokenPipeError("MCP stdin accepted zero bytes")
                view = view[written:]
        except (BrokenPipeError, OSError) as error:
            diagnostic = self.stderr_tail().strip()
            detail = f"; stderr tail: {diagnostic}" if diagnostic else ""
            raise RuntimeError(f"failed writing to MCP stdin: {error}{detail}") from error

    def receive(
        self,
        timeout: float = 30.0,
        *,
        deadline: float | None = None,
    ) -> dict[str, object]:
        if deadline is None:
            deadline = time.monotonic() + timeout
        while True:
            with self._stdout_error_lock:
                stdout_error = self._stdout_error
            if stdout_error is not None:
                raise RuntimeError(stdout_error)

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for an MCP response")
            try:
                line = self._messages.get(timeout=min(remaining, 0.05))
                break
            except queue.Empty:
                if self._stdout_eof.is_set() and self._messages.empty():
                    diagnostic = self.stderr_tail().strip()
                    detail = f"; stderr tail: {diagnostic}" if diagnostic else ""
                    raise RuntimeError(
                        f"MCP exited before responding (code {self.process.poll()}){detail}"
                    )
        try:
            decoded = line.decode("utf-8")
            message = json.loads(decoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            preview = line[:200]
            raise RuntimeError(f"MCP emitted invalid JSON stdout: {preview!r}") from error
        if not isinstance(message, dict):
            raise RuntimeError(f"MCP emitted a non-object message: {message!r}")
        if message.get("jsonrpc") != "2.0":
            raise RuntimeError(f"MCP emitted an invalid JSON-RPC message: {message!r}")
        return message

    def request(
        self,
        method: str,
        params: dict[str, object],
        *,
        timeout: float = 30.0,
    ) -> dict[str, object]:
        request_id = self.next_id
        self.next_id += 1
        deadline = time.monotonic() + timeout
        self.send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            },
            deadline=deadline,
        )
        while True:
            message = self.receive(deadline=deadline)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError(f"MCP {method} failed: {message['error']}")
            if "result" not in message:
                raise RuntimeError(
                    f"MCP {method} returned neither a result nor an error: {message!r}"
                )
            return message

    def notify(self, method: str, params: dict[str, object]) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self) -> str:
        if self._closed:
            return self.stderr_tail()
        self._closed = True
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass

        graceful_timeout, terminate_timeout, kill_timeout = self._shutdown_timeouts
        try:
            self.process.wait(timeout=graceful_timeout)
        except subprocess.TimeoutExpired:
            if self.process.poll() is None:
                try:
                    self.process.terminate()
                except ProcessLookupError:
                    pass
            try:
                self.process.wait(timeout=terminate_timeout)
            except subprocess.TimeoutExpired:
                if self.process.poll() is None:
                    try:
                        self.process.kill()
                    except ProcessLookupError:
                        pass
                try:
                    self.process.wait(timeout=kill_timeout)
                except subprocess.TimeoutExpired:
                    with self._stderr_lock:
                        note = b"\nMCP process did not exit after kill\n"
                        self._stderr_tail.extend(note)
                        excess = len(self._stderr_tail) - _STDERR_TAIL_BYTES
                        if excess > 0:
                            del self._stderr_tail[:excess]

        self._stdout_thread.join(timeout=0.2)
        self._stderr_thread.join(timeout=0.2)
        for pipe in (self.process.stdout, self.process.stderr):
            if pipe is not None:
                try:
                    pipe.close()
                except OSError:
                    pass
        return self.stderr_tail()


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
    print("Browser MCP smoke test passed: initialize, browser_navigate, browser_snapshot, and browser_close")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
