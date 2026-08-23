#!/usr/bin/env python3
"""Hermetic fake line-delimited JSON-RPC server for MCP smoke-client tests."""

from __future__ import annotations

import json
import os
import signal
import sys
import time


def emit(message: object) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


mode = os.environ.get("MCP_SMOKE_FAKE_MODE", "normal")

if mode == "hung_term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)

if mode == "non_reading":
    while True:
        time.sleep(1)

for request_line in sys.stdin:
    request = json.loads(request_line)
    request_id = request.get("id")
    if request_id is None:
        continue

    if mode == "back_to_back":
        notification = {"jsonrpc": "2.0", "method": "notifications/progress"}
        response = {"jsonrpc": "2.0", "id": request_id, "result": {"ok": True}}
        payload = json.dumps(notification) + "\n" + json.dumps(response) + "\n"
        os.write(sys.stdout.fileno(), payload.encode("utf-8"))
    elif mode == "stderr_flood":
        block = b"stderr-noise-" + (b"x" * 1010) + b"\n"
        for _ in range(2048):
            os.write(sys.stderr.fileno(), block)
        emit({"jsonrpc": "2.0", "id": request_id, "result": {"ok": True}})
    elif mode == "notification_spam":
        end = time.monotonic() + 0.6
        while time.monotonic() < end:
            emit({"jsonrpc": "2.0", "method": "notifications/progress"})
            time.sleep(0.005)
    elif mode == "invalid_json":
        os.write(sys.stdout.fileno(), b"{not-json}\n")
    elif mode == "protocol_error":
        emit({"jsonrpc": "2.0", "id": request_id})
    elif mode == "eof_error":
        sys.stderr.write("fake server exited deliberately\n")
        sys.stderr.flush()
        raise SystemExit(7)
    elif mode == "environment":
        emit(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "runtime": os.environ.get("BROWSER_WORKBENCH_RUNTIME_DIR"),
                    "browsers": os.environ.get("BROWSER_WORKBENCH_BROWSERS_PATH"),
                },
            }
        )
    else:
        emit({"jsonrpc": "2.0", "id": request_id, "result": {"ok": True}})
