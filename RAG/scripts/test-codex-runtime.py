#!/usr/bin/env python3
"""Isolated fixture tests for the repo-bootstrap Codex runtime helpers."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest


HERE = Path(__file__).resolve().parent
MEMORY = HERE / "codex-memory.py"
RELAY = HERE / "codex-relay-wake.py"


def executable(path: Path, body: str) -> Path:
    path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
    path.chmod(0o755)
    return path


class CodexMemoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "memory"
        self.handoffs = Path(self.temp.name) / "handoffs"
        self.handoffs.mkdir()
        self.summarizer = executable(Path(self.temp.name) / "summarize", """
            #!/usr/bin/env python3
            import sys
            sys.stdin.read()
            print("User chose the event-driven Codex runtime setup")
        """)
        self.env = os.environ.copy()
        self.env["CODEX_MEMORY_NO_SPAWN"] = "1"
        self.env["MEMLOG_SUMMARIZER_CMD"] = str(self.summarizer)

    def tearDown(self):
        self.temp.cleanup()

    def hook(self, command: str, payload: dict, *extra: str,
             check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(MEMORY), command, str(self.root), *extra],
            input=json.dumps(payload), text=True, capture_output=True,
            env=self.env, check=check,
        )

    def test_exact_exchange_commit_and_context_injection(self):
        prompt = "Please preserve `x < y` and this exact\nsecond line."
        response = "Done. I preserved `x < y`.\nNo extra changes."
        common = {"session_id": "session/one", "turn_id": "turn:1", "model": "test"}
        self.hook("capture", {**common, "prompt": prompt})
        self.hook("stop", {**common, "last_assistant_message": response})
        queued = list((self.root / ".codex-memory" / "queue").glob("*.json"))
        self.assertEqual(len(queued), 1)

        drained = subprocess.run(
            [sys.executable, str(MEMORY), "drain", str(self.root)],
            text=True, capture_output=True, env=self.env,
        )
        self.assertEqual(drained.returncode, 0, drained.stderr)
        files = list((self.root / "exchanges").rglob("*.json"))
        self.assertEqual(len(files), 1)
        exchange = json.loads(files[0].read_text(encoding="utf-8"))
        self.assertEqual(exchange["user"], prompt)
        self.assertEqual(exchange["assistant"], response)
        subject = subprocess.check_output(
            ["git", "-C", str(self.root), "log", "-1", "--format=%s"], text=True,
        ).strip()
        self.assertEqual(subject, "User chose the event-driven Codex runtime setup")
        status = subprocess.check_output(
            ["git", "-C", str(self.root), "status", "--short"], text=True,
        )
        self.assertEqual(status, "")

        (self.handoffs / "AI-LOG-009.md").write_text("Current work: runtime hooks.\n", encoding="utf-8")
        injected = self.hook(
            "inject", {"source": "resume"}, "--handoff-dir", str(self.handoffs),
            "--count", "5",
        )
        output = json.loads(injected.stdout)
        context = output["hookSpecificOutput"]["additionalContext"]
        self.assertIn("Current work: runtime hooks.", context)
        self.assertIn(subject, context)
        self.assertNotIn(response, context)

    def test_noise_prompt_is_not_committed(self):
        common = {"session_id": "s", "turn_id": "t"}
        self.hook("capture", {**common, "prompt": "scan the channel"})
        self.hook("stop", {**common, "last_assistant_message": "No new event."})
        self.assertFalse((self.root / ".codex-memory" / "queue").exists())

    def test_stop_detaches_drain(self):
        common = {"session_id": "detached", "turn_id": "one"}
        self.hook("capture", {**common, "prompt": "Remember this asynchronously."})
        env = self.env.copy()
        env.pop("CODEX_MEMORY_NO_SPAWN")
        stopped = subprocess.run(
            [sys.executable, str(MEMORY), "stop", str(self.root)],
            input=json.dumps({**common, "last_assistant_message": "I will."}),
            text=True, capture_output=True, env=env,
        )
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not (self.root / ".git").exists():
            time.sleep(0.02)
        while time.monotonic() < deadline:
            result = subprocess.run(
                ["git", "-C", str(self.root), "rev-list", "--count", "HEAD"],
                text=True, capture_output=True,
            )
            if result.returncode == 0 and result.stdout.strip() == "1":
                break
            time.sleep(0.02)
        else:
            self.fail("detached memory drain did not create its commit")


class CodexRelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.repo = base / "repo"
        self.outbox = self.repo / ".codex" / "outbox"
        self.outbox.mkdir(parents=True)
        self.state = base / "state"
        self.carrier_log = base / "carrier.log"
        self.codex_log = base / "codex.log"
        self.carrier = executable(base / "fake-carrier.py", f"""
            #!/usr/bin/env python3
            from pathlib import Path
            import sys
            Path({str(self.carrier_log)!r}).open("a").write(" ".join(sys.argv[1:]) + "\\n")
        """)
        self.codex = executable(base / "fake-codex", f"""
            #!/usr/bin/env python3
            import json, os, sys
            from pathlib import Path
            with Path({str(self.codex_log)!r}).open("a") as handle:
                handle.write(json.dumps(sys.argv[1:]) + "\\n")
            if os.environ.get("FAKE_CODEX_FAIL"):
                print("forced wake failure", file=sys.stderr)
                raise SystemExit(9)
        """)
        self.env = os.environ.copy()

    def tearDown(self):
        self.temp.cleanup()

    def wake(self, *, fail: bool = False,
             quiet_seconds: str = "0") -> subprocess.CompletedProcess:
        env = self.env.copy()
        if fail:
            env["FAKE_CODEX_FAIL"] = "1"
        return subprocess.run([
            sys.executable, str(RELAY),
            "--repo", str(self.repo),
            "--thread-id", "thread-123",
            "--carrier-script", str(self.carrier),
            "--state-dir", str(self.state),
            "--codex-command", str(self.codex),
            "--quiet-seconds", quiet_seconds,
        ], text=True, capture_output=True, env=env)

    def codex_calls(self) -> list[list[str]]:
        if not self.codex_log.exists():
            return []
        return [json.loads(line) for line in self.codex_log.read_text().splitlines()]

    def test_change_only_wake_uses_fixed_prompt(self):
        secret = "channel body must not enter wake prompt"
        message = self.outbox / "message.md"
        message.write_text(secret, encoding="utf-8")
        first = self.wake()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.codex_calls(), [[
            "exec", "resume", "thread-123", "scan the channel",
        ]])
        self.assertNotIn(secret, json.dumps(self.codex_calls()))
        self.assertIn("sync --repo", self.carrier_log.read_text())

        unchanged = self.wake()
        self.assertEqual(unchanged.returncode, 0, unchanged.stderr)
        self.assertEqual(len(self.codex_calls()), 1)

        message.write_text(secret + " version two", encoding="utf-8")
        changed = self.wake()
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertEqual(len(self.codex_calls()), 2)

    def test_failed_wake_retains_and_retries_pending_marker(self):
        (self.outbox / "message.md").write_text("version one", encoding="utf-8")
        self.assertEqual(self.wake().returncode, 0)
        (self.outbox / "message.md").write_text("version two", encoding="utf-8")
        failed = self.wake(fail=True)
        self.assertNotEqual(failed.returncode, 0)
        pending = self.state / "pending.json"
        self.assertTrue(pending.exists())
        attempts = json.loads(pending.read_text())["attempts"]
        self.assertEqual(attempts, 1)

        retried = self.wake()
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertFalse(pending.exists())
        self.assertEqual(len(self.codex_calls()), 3)

    def test_mid_write_waits_for_quiet_second_sample(self):
        message = self.outbox / "message.md"
        message.write_text("partial", encoding="utf-8")
        writer = threading.Thread(
            target=lambda: (time.sleep(0.02), message.write_text("complete", encoding="utf-8")),
        )
        writer.start()
        result = self.wake(quiet_seconds="0.05")
        writer.join()
        self.assertEqual(result.returncode, 0, result.stderr)
        delivered = json.loads((self.state / "delivered.json").read_text())
        self.assertEqual(
            delivered["watched"][0]["sha256"],
            __import__("hashlib").sha256(b"complete").hexdigest(),
        )
        self.assertEqual(len(self.codex_calls()), 1)


if __name__ == "__main__":
    unittest.main()
