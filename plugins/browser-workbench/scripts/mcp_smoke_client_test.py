#!/usr/bin/env python3
"""Hermetic tests for the MCP smoke-test client transport."""

from __future__ import annotations

import os
import signal
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from mcp_smoke_test import McpClient


SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
FAKE_SERVER = SCRIPT_DIR / "mcp_smoke_fake_server_fixture.py"


class McpSmokeClientTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        directory = Path(self.temporary_directory.name)
        self.launcher = directory / "fake-launcher.sh"
        self.launcher.write_text(
            '#!/usr/bin/env bash\nexec "${PYTHON:-python3}" "${MCP_SMOKE_FAKE_SERVER}"\n',
            encoding="utf-8",
        )

    def client(self, mode: str, **kwargs: object) -> McpClient:
        environment = {
            "MCP_SMOKE_FAKE_MODE": mode,
            "MCP_SMOKE_FAKE_SERVER": str(FAKE_SERVER),
        }
        patcher = mock.patch.dict(os.environ, environment)
        patcher.start()
        self.addCleanup(patcher.stop)
        client = McpClient(self.launcher, PLUGIN_ROOT, **kwargs)
        self.addCleanup(client.close)
        return client

    def test_normal_request_succeeds(self) -> None:
        response = self.client("normal").request("example", {})
        self.assertEqual(response["result"], {"ok": True})

    def test_back_to_back_notification_and_response_do_not_timeout(self) -> None:
        response = self.client("back_to_back").request("example", {}, timeout=0.5)
        self.assertEqual(response["result"], {"ok": True})

    def test_stderr_flood_is_drained_and_retained_as_a_bounded_tail(self) -> None:
        client = self.client("stderr_flood")
        response = client.request("example", {}, timeout=2.0)
        self.assertEqual(response["result"], {"ok": True})
        diagnostic = client.close()
        self.assertIn("stderr-noise", diagnostic)
        self.assertLessEqual(len(diagnostic.encode("utf-8")), 64 * 1024)

    def test_notification_spam_does_not_extend_request_deadline(self) -> None:
        client = self.client("notification_spam")
        started = time.monotonic()
        with self.assertRaisesRegex(TimeoutError, "timed out"):
            client.request("example", {}, timeout=0.1)
        self.assertLess(time.monotonic() - started, 0.35)

    def test_non_reading_server_cannot_block_past_request_deadline(self) -> None:
        client = self.client(
            "non_reading",
            shutdown_timeouts=(0.05, 0.05, 0.5),
        )
        bounded_large_payload = "x" * (2 * 1024 * 1024)
        started = time.monotonic()
        with self.assertRaisesRegex(
            RuntimeError,
            "failed writing to MCP stdin: timed out writing MCP request",
        ) as caught:
            client.request(
                "example",
                {"payload": bounded_large_payload},
                timeout=0.1,
            )
        self.assertIsInstance(caught.exception.__cause__, TimeoutError)
        self.assertLess(time.monotonic() - started, 0.5)

    def test_invalid_json_is_actionable(self) -> None:
        client = self.client("invalid_json")
        with self.assertRaisesRegex(RuntimeError, "invalid JSON.*not-json"):
            client.request("example", {})

    def test_invalid_response_shape_is_actionable(self) -> None:
        client = self.client("protocol_error")
        with self.assertRaisesRegex(RuntimeError, "neither a result nor an error"):
            client.request("example", {})

    def test_protocol_eof_reports_process_failure_and_stderr(self) -> None:
        client = self.client("eof_error")
        with self.assertRaisesRegex(RuntimeError, "MCP exited before responding"):
            client.request("example", {})
        self.assertIn("exited deliberately", client.close())

    def test_runtime_and_browser_cache_overrides_are_preserved(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "BROWSER_WORKBENCH_RUNTIME_DIR": "/custom/runtime",
                "BROWSER_WORKBENCH_BROWSERS_PATH": "/custom/browsers",
            },
        ):
            result = self.client("environment").request("environment", {})["result"]
        self.assertEqual(result["runtime"], "/custom/runtime")
        self.assertEqual(result["browsers"], "/custom/browsers")

    def test_close_kills_process_that_ignores_sigterm(self) -> None:
        client = self.client(
            "hung_term",
            shutdown_timeouts=(0.05, 0.05, 0.5),
        )
        time.sleep(0.1)
        client.close()
        self.assertEqual(client.process.returncode, -signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
