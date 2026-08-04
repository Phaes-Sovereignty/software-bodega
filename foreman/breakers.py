"""breakers.py — the circuit breakers that end a night deliberately.

A night must be able to stop badly without stopping stupidly: it should give up
on a task that is not converging, ratchet down progress that IS real, and refuse
to grind on the same traceback until morning.

State is on disk (factory/.planning/breakers.json) so a resume after kill -9
does not reset a breaker that had already tripped.

The exit condition stays dual: all tasks resolved AND an explicit exit signal.
Either alone is a way to stop early on a lie.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class BreakerState:
    parks: int = 0
    consecutive_empty_diffs: int = 0
    same_error_count: int = 0
    last_error: str = ""
    tasks_since_ratchet: int = 0
    opened_at: float = 0.0          # when the breaker tripped (0 = closed)
    open_reason: str = ""
    half_open: bool = False
    history: list[dict[str, Any]] = field(default_factory=list)


class Breakers:
    """Thresholds are deliberately small. A night that needs more than this is
    a night that should wake someone up instead."""

    PARK_STOP = 3            # 3 parked tasks -> stop the night and notify
    EMPTY_DIFF_PARK = 3      # 3 no-progress iterations -> park the task
    SAME_ERROR_PARK = 5      # the same traceback 5 times -> park
    RATCHET_EVERY = (5, 7)   # commit a checkpoint every 5-7 completed tasks
    COOLDOWN_S = 30 * 60     # 30 minutes, then a single half-open retry

    def __init__(self, root: Path, clock=time.time):
        self.path = Path(root) / "factory/.planning/breakers.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.clock = clock
        self.state = self._load()

    def _load(self) -> BreakerState:
        if self.path.exists():
            try:
                return BreakerState(**json.loads(self.path.read_text()))
            except (json.JSONDecodeError, TypeError):
                pass
        return BreakerState()

    def save(self) -> None:
        self.path.write_text(json.dumps(asdict(self.state), indent=2) + "\n")

    def _note(self, event: str, detail: str = "") -> None:
        self.state.history.append(
            {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
             "event": event, "detail": detail})
        self.save()

    # --- signals in --------------------------------------------------------
    def record_park(self, task_id: str, reason: str) -> bool:
        """A task parked. Returns True if the night should STOP."""
        self.state.parks += 1
        self._note("park", f"{task_id}: {reason}")
        if self.state.parks >= self.PARK_STOP:
            self.trip(f"{self.state.parks} tasks parked")
            return True
        return False

    def record_empty_diff(self, task_id: str) -> bool:
        """A worker claimed progress but changed nothing. True -> park it."""
        self.state.consecutive_empty_diffs += 1
        self._note("empty_diff", f"{task_id} ({self.state.consecutive_empty_diffs})")
        return self.state.consecutive_empty_diffs >= self.EMPTY_DIFF_PARK

    def record_error(self, signature: str) -> bool:
        """Same failure signature repeatedly. True -> park it."""
        if signature and signature == self.state.last_error:
            self.state.same_error_count += 1
        else:
            self.state.last_error = signature
            self.state.same_error_count = 1
        self._note("error", f"{signature[:80]} x{self.state.same_error_count}")
        return self.state.same_error_count >= self.SAME_ERROR_PARK

    def record_progress(self, task_id: str) -> bool:
        """A task genuinely completed. True -> take a ratchet checkpoint."""
        self.state.consecutive_empty_diffs = 0
        self.state.same_error_count = 0
        self.state.last_error = ""
        self.state.tasks_since_ratchet += 1
        self._note("progress", task_id)
        if self.state.tasks_since_ratchet >= self.RATCHET_EVERY[0]:
            return True
        return False

    def ratchet(self) -> None:
        """Checkpoint taken: real progress is banked and the counter resets."""
        self.state.tasks_since_ratchet = 0
        self._note("ratchet", "checkpoint committed")

    # --- breaker state -----------------------------------------------------
    def trip(self, reason: str) -> None:
        self.state.opened_at = self.clock()
        self.state.open_reason = reason
        self.state.half_open = False
        self._note("trip", reason)

    @property
    def is_open(self) -> bool:
        return self.state.opened_at > 0 and not self.may_retry()

    def may_retry(self) -> bool:
        """After the cooldown, allow exactly ONE half-open attempt.

        Half-open, not reset: if the retry fails the breaker slams shut again
        rather than starting another full cycle of the same failure.
        """
        if self.state.opened_at <= 0:
            return True
        if self.state.half_open:
            return False
        if self.clock() - self.state.opened_at >= self.COOLDOWN_S:
            self.state.half_open = True
            self._note("half_open", "cooldown elapsed; one retry allowed")
            return True
        return False

    def reset(self) -> None:
        self.state = BreakerState()
        self.save()

    def cooldown_remaining(self) -> float:
        if self.state.opened_at <= 0:
            return 0.0
        return max(0.0, self.COOLDOWN_S - (self.clock() - self.state.opened_at))

    # --- exit condition ----------------------------------------------------
    @staticmethod
    def may_exit(all_resolved: bool, exit_signal: bool) -> bool:
        """Both, always. Either one alone is a way to stop early on a lie:
        a worker can emit EXIT_SIGNAL while tasks remain, and tasks can all be
        'resolved' because they were parked."""
        return bool(all_resolved and exit_signal)

    def summary(self) -> dict[str, Any]:
        s = self.state
        return {
            "parks": s.parks, "empty_diffs": s.consecutive_empty_diffs,
            "same_error": s.same_error_count,
            "open": bool(s.opened_at) and not s.half_open,
            "reason": s.open_reason,
            "cooldown_s": round(self.cooldown_remaining()),
            "events": len(s.history),
        }
