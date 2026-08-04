"""fsm.py — the station machine. The foreman's authority lives here.

Transitions are an enumerated table. There is no "advance to whatever comes
next": a move from A to B exists or it does not, and it fires only when a PASS
verdict for the named gate is on disk, bound to the current artifact SHA.

Three properties the table buys us:

- **Illegal moves are impossible**, not merely discouraged. Skipping the exam
  board is not a policy violation; it is a transition that does not exist.
- **Verdicts are SHA-bound.** A pass recorded against an older artifact does not
  open the gate, so editing the spec after approval re-closes it automatically.
- **Temporal validation.** A verdict that predates the station being entered is
  evidence about a previous attempt, not this one.
"""
from __future__ import annotations

import calendar
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .contracts import Store

# Stations. BACKLOG is terminal-success; BLOCKED is terminal-recoverable.
STATIONS = ["INTERVIEW", "SPEC", "BLUEPRINT", "EXAM", "WORKORDER", "BACKLOG", "BLOCKED"]

# (from_station, gate) -> to_station. The whole legal surface of the pipeline.
TRANSITIONS: dict[tuple[str, str], str] = {
    ("INTERVIEW", "brief"):         "SPEC",
    ("SPEC",      "spec"):          "BLUEPRINT",
    ("BLUEPRINT", "decompose"):     "EXAM",
    ("BLUEPRINT", "design_record"): "EXAM",
    ("EXAM",      "exam"):          "WORKORDER",
    ("WORKORDER", "plan"):          "WORKORDER",   # plan_gate keeps you in place
    ("WORKORDER", "plan_review"):   "BACKLOG",     # only the judged gate exits
}

# Gates that must ALL pass before leaving a station, where a station has more
# than one. BLUEPRINT needs both the graph and the design records.
REQUIRED: dict[str, tuple[str, ...]] = {
    "INTERVIEW": ("brief",),
    "SPEC":      ("spec",),
    "BLUEPRINT": ("decompose", "design_record"),
    "EXAM":      ("exam",),
    "WORKORDER": ("plan", "plan_review"),
}


class IllegalTransition(Exception):
    pass


class GateNotPassed(Exception):
    pass


@dataclass
class Transition:
    frm: str
    gate: str
    to: str
    sha: str
    ts: str


class FSM:
    def __init__(self, root: Path, store: Store | None = None,
                 clock: Callable[[], float] = time.time):
        self.root = Path(root)
        self.store = store or Store(self.root)
        self.clock = clock
        self.state_path = self.root / "factory/STATE.md"
        self.log_path = self.root / "factory/log.md"
        self.entered_path = self.root / "factory/.planning/.station-entered"

    # --- state ------------------------------------------------------------
    def station(self) -> str:
        if not self.state_path.exists():
            return "INTERVIEW"
        for line in self.state_path.read_text().splitlines():
            if line.startswith("STAGE:"):
                s = line.split(":", 1)[1].strip().upper()
                return s if s in STATIONS else "INTERVIEW"
        return "INTERVIEW"

    def pointer(self) -> str:
        if not self.state_path.exists():
            return ""
        for line in self.state_path.read_text().splitlines():
            if line.startswith("POINTER:"):
                return line.split(":", 1)[1].strip()
        return ""

    def entered_at(self) -> float:
        try:
            return float(self.entered_path.read_text().strip())
        except (OSError, ValueError):
            return 0.0

    def _write_state(self, station: str, pointer: str) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(f"STAGE: {station}\nPOINTER: {pointer}\n")
        self.entered_path.parent.mkdir(parents=True, exist_ok=True)
        self.entered_path.write_text(f"{self.clock()}\n")

    def _log(self, event: str, detail: str) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self.log_path.open("a") as fh:
            fh.write(f"{ts}|foreman|{event}|{detail}\n")

    # --- queries ----------------------------------------------------------
    @staticmethod
    def legal_gates(station: str) -> list[str]:
        return [g for (f, g) in TRANSITIONS if f == station]

    @staticmethod
    def target(station: str, gate: str) -> str | None:
        return TRANSITIONS.get((station, gate))

    def satisfied(self, station: str, sha: str) -> list[str]:
        """Which of this station's required gates already have a PASS at `sha`."""
        return [g for g in REQUIRED.get(station, ()) if self.store.has_pass(g, sha)]

    def ready_to_leave(self, station: str, sha: str) -> bool:
        req = REQUIRED.get(station, ())
        return bool(req) and all(self.store.has_pass(g, sha) for g in req)

    # --- the one mutating operation ---------------------------------------
    def fire(self, gate: str, sha: str, pointer: str = "", force: bool = False) -> Transition:
        """Attempt the transition (current station, gate). Raises unless legal.

        `force` skips the verdict requirement but NOT the legality check — used
        by `resume` when replaying a transition whose verdict was already
        consumed. It can never invent a transition the table does not contain.
        """
        frm = self.station()
        to = TRANSITIONS.get((frm, gate))
        if to is None:
            legal = ", ".join(sorted(self.legal_gates(frm))) or "(none)"
            raise IllegalTransition(
                f"no transition ({frm}, {gate}); legal gates here: {legal}")

        if not force:
            v = self.store.verdict(gate, sha)
            if v is None:
                raise GateNotPassed(
                    f"gate {gate!r} has no verdict for artifact {sha[:12]} — "
                    "a gate that did not run is a gate that failed")
            if not v.passed:
                raise GateNotPassed(f"gate {gate!r} verdict for {sha[:12]} is not a pass: {v.verdict}")
            # Temporal validation: a verdict older than the station entry is
            # evidence about a previous attempt at this station.
            entered = self.entered_at()
            if entered and v.ts:
                try:
                    # timegm, NOT mktime: verdict timestamps are UTC, and mktime
                    # reads the struct as local time. That offset (7h here) pushed
                    # stale verdicts into the future and disabled this check.
                    vt = calendar.timegm(time.strptime(v.ts, "%Y-%m-%dT%H:%M:%SZ"))
                    if vt < entered - 1:
                        raise GateNotPassed(
                            f"gate {gate!r} verdict predates entry to {frm} "
                            f"({v.ts}) — stale evidence")
                except ValueError:
                    pass  # unparseable timestamp: fall through, the SHA still binds

            # Leaving a station requires ALL of its gates, not just this one.
            if to != frm:
                missing = [g for g in REQUIRED.get(frm, ()) if not self.store.has_pass(g, sha)]
                if missing:
                    raise GateNotPassed(
                        f"cannot leave {frm}: gates still unpassed at {sha[:12]}: {missing}")

        self._write_state(to, pointer or f"entered via {gate}")
        self._log("transition", f"{frm} --{gate}--> {to} @ {sha[:12]}")
        return Transition(frm, gate, to, sha, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))

    def block(self, reason: str) -> Transition:
        """BLOCKED is reachable from anywhere and always carries a reason."""
        if not reason.strip():
            raise ValueError("BLOCKED requires a reason")
        frm = self.station()
        self._write_state("BLOCKED", reason)
        self._log("blocked", f"{frm}: {reason}")
        return Transition(frm, "block", "BLOCKED", "", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))

    def resume(self, station: str | None = None) -> str:
        """Come back from BLOCKED to the station that blocked, or a named one."""
        if self.station() != "BLOCKED" and station is None:
            return self.station()
        target = station or self._blocked_from() or "INTERVIEW"
        if target not in STATIONS:
            raise IllegalTransition(f"unknown station {target!r}")
        self._write_state(target, "resumed from BLOCKED")
        self._log("resume", f"BLOCKED -> {target}")
        return target

    def _blocked_from(self) -> str | None:
        if not self.log_path.exists():
            return None
        for line in reversed(self.log_path.read_text().splitlines()):
            if "|blocked|" in line:
                frm = line.split("|blocked|", 1)[1].split(":", 1)[0].strip()
                if frm in STATIONS:
                    return frm
        return None
