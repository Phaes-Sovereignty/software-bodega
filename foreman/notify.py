"""notify.py — one webhook, three occasions.

STOP, park, morning debrief. That is the entire notification surface, on purpose:
a factory that pages you about routine progress trains you to ignore it, and the
one message that mattered arrives in a stream you have stopped reading.

Delivery never raises into the caller. A dead webhook must not take down a night
that is otherwise fine; it is logged and the run continues.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

OCCASIONS = ("stop", "park", "debrief")


class Notifier:
    def __init__(self, root: Path, url: str | None = None, timeout: int = 10):
        self.root = Path(root)
        self.url = url or os.environ.get("FACTORY_WEBHOOK", "")
        self.timeout = timeout
        self.outbox = self.root / "factory/.planning/notifications.jsonl"
        self.outbox.parent.mkdir(parents=True, exist_ok=True)

    def send(self, occasion: str, title: str, body: str = "",
             extra: dict[str, Any] | None = None) -> bool:
        if occasion not in OCCASIONS:
            raise ValueError(f"occasion must be one of {OCCASIONS}, got {occasion!r}")
        payload = {
            "occasion": occasion,
            "title": title,
            "body": body,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            **(extra or {}),
        }
        # Always journal, even with no webhook configured: the morning debrief
        # should be readable from disk whether or not delivery worked.
        with self.outbox.open("a") as fh:
            fh.write(json.dumps(payload, separators=(",", ":")) + "\n")
        if not self.url:
            return False
        try:
            req = urllib.request.Request(
                self.url, data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return 200 <= resp.status < 300
        except (urllib.error.URLError, OSError, ValueError) as e:
            # Never raise: a dead webhook is not a reason to lose a night.
            with self.outbox.open("a") as fh:
                fh.write(json.dumps({"delivery_error": str(e)[:200],
                                     "ts": payload["ts"]}) + "\n")
            return False

    def stop(self, reason: str, **extra: Any) -> bool:
        return self.send("stop", "Factory STOPPED", reason, extra)

    def park(self, task_id: str, reason: str, **extra: Any) -> bool:
        return self.send("park", f"Task {task_id} parked", reason, extra)

    def debrief(self, summary: str, **extra: Any) -> bool:
        return self.send("debrief", "Morning debrief", summary, extra)

    def history(self, limit: int = 20) -> list[dict[str, Any]]:
        if not self.outbox.exists():
            return []
        rows = []
        for line in self.outbox.read_text().splitlines()[-limit:]:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return rows
