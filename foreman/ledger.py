"""ledger.py — append-only accounting for the night.

One JSON object per line in factory/ledger.jsonl. Append-only: rows are never
edited or removed, because the ledger is the only place that can answer "what
did last night actually cost, and where did it go".

Ceilings: exactly one dimension blocks (rounds), the other observes and warns
(tokens). Two blocking ceilings means a night can die for a reason nobody chose
and the ledger cannot say which limit was the real one.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any, Iterator


class CeilingExceeded(Exception):
    """A blocking ceiling was hit. The night stops."""


@dataclass
class Row:
    ts: str = ""
    station: str = "-"
    task_id: str = "-"
    model: str = "-"
    role: str = "-"
    rounds: int = 0
    tokens_in: int = 0
    tokens_out: int = 0
    wall_s: float = 0.0
    note: str = ""
    extra: dict[str, Any] = field(default_factory=dict)


class Ledger:
    def __init__(self, root: Path, ceilings: dict[str, Any] | None = None):
        self.path = Path(root) / "factory/ledger.jsonl"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.ceilings = ceilings or {
            "rounds": {"limit": 40, "action": "block"},
            "tokens": {"limit": 4_000_000, "action": "warn", "warn_at": 0.8},
        }
        self._warned: set[str] = set()

    # --- writing ----------------------------------------------------------
    def append(self, row: Row) -> Row:
        if not row.ts:
            row.ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self.path.open("a") as fh:
            fh.write(json.dumps(asdict(row), separators=(",", ":")) + "\n")
        return row

    def record(self, **kw: Any) -> Row:
        return self.append(Row(**kw))

    # --- reading ----------------------------------------------------------
    def rows(self) -> Iterator[Row]:
        if not self.path.exists():
            return
        for line in self.path.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue  # a torn final line never invalidates the history
            yield Row(**{k: d.get(k, getattr(Row(), k)) for k in Row.__dataclass_fields__})

    def totals(self) -> dict[str, Any]:
        t = {"rounds": 0, "tokens_in": 0, "tokens_out": 0, "wall_s": 0.0, "entries": 0}
        for r in self.rows():
            t["rounds"] += r.rounds
            t["tokens_in"] += r.tokens_in
            t["tokens_out"] += r.tokens_out
            t["wall_s"] += r.wall_s
            t["entries"] += 1
        t["tokens"] = t["tokens_in"] + t["tokens_out"]
        return t

    def by_role(self) -> dict[str, dict[str, int]]:
        out: dict[str, dict[str, int]] = {}
        for r in self.rows():
            b = out.setdefault(r.role, {"rounds": 0, "tokens": 0})
            b["rounds"] += r.rounds
            b["tokens"] += r.tokens_in + r.tokens_out
        return out

    # --- ceilings ---------------------------------------------------------
    def check(self) -> list[str]:
        """Enforce blocking ceilings, warn on observing ones.

        Returns warnings. Raises CeilingExceeded when a blocking limit is hit.
        """
        t = self.totals()
        warnings: list[str] = []
        for name, spec in self.ceilings.items():
            limit = spec.get("limit")
            if not limit:
                continue
            used = t.get(name, 0)
            action = spec.get("action", "warn")
            if action == "block":
                if used >= limit:
                    raise CeilingExceeded(
                        f"{name} ceiling reached: {used}/{limit} — stopping the night"
                    )
            else:
                frac = spec.get("warn_at", 0.8)
                if used >= limit * frac and name not in self._warned:
                    self._warned.add(name)
                    warnings.append(
                        f"{name} at {used}/{limit} ({used / limit:.0%}) — observing only, not blocking"
                    )
        return warnings

    def remaining(self, name: str) -> int | None:
        spec = self.ceilings.get(name) or {}
        limit = spec.get("limit")
        if not limit:
            return None
        return max(0, limit - self.totals().get(name, 0))
