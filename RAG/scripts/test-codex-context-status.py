#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("codex-context-status.py")
SPEC = importlib.util.spec_from_file_location("codex_context_status", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ContextStatusTests(unittest.TestCase):
    def test_reads_latest_valid_token_event(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            rollout = Path(temp_dir) / "rollout-thread-1.jsonl"
            rows = [
                {"type": "event_msg", "payload": {"type": "other"}},
                {
                    "timestamp": "2026-08-06T01:00:00Z",
                    "type": "event_msg",
                    "payload": {
                        "type": "token_count",
                        "info": {
                            "last_token_usage": {"total_tokens": 10},
                            "model_context_window": 100,
                        },
                    },
                },
                {
                    "timestamp": "2026-08-06T02:00:00Z",
                    "type": "event_msg",
                    "payload": {
                        "type": "token_count",
                        "info": {
                            "last_token_usage": {"total_tokens": 40},
                            "model_context_window": 100,
                        },
                    },
                },
            ]
            rollout.write_text(
                "not json\n" + "\n".join(json.dumps(row) for row in rows) + "\n",
                encoding="utf-8",
            )

            status = MODULE.read_status(rollout, "thread-1")

            self.assertEqual(status.used_tokens, 40)
            self.assertEqual(status.remaining_tokens, 60)
            self.assertEqual(status.used_percent, 40.0)
            self.assertEqual(status.remaining_percent, 60.0)
            self.assertEqual(status.observed_at, "2026-08-06T02:00:00Z")

    def test_finds_newest_matching_rollout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            sessions = Path(temp_dir)
            older = sessions / "a" / "rollout-thread-1.jsonl"
            newer = sessions / "b" / "rollout-thread-1.jsonl"
            older.parent.mkdir()
            newer.parent.mkdir()
            older.write_text("{}\n", encoding="utf-8")
            newer.write_text("{}\n", encoding="utf-8")
            os.utime(older, ns=(1_000_000_000, 1_000_000_000))
            os.utime(newer, ns=(2_000_000_000, 2_000_000_000))

            self.assertEqual(MODULE.find_rollout(sessions, "thread-1"), newer)


if __name__ == "__main__":
    unittest.main()
