"""router.py — role → model resolution and the independence invariants.

Model identities live in routing.yaml and nowhere else. Everything upstream
speaks in roles, so swapping a provider never touches a prompt or a gate.
"""
from __future__ import annotations

import fnmatch
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

HERE = Path(__file__).resolve().parent


class FamilyViolation(Exception):
    """A judge shares a model family with the author it is meant to check."""


class UnknownRole(Exception):
    pass


@dataclass(frozen=True)
class Role:
    name: str
    model: str
    family: str
    cmd: tuple[str, ...]
    input: str  # "stdin" | "arg"


class Router:
    def __init__(self, config: dict[str, Any] | None = None, path: Path | None = None):
        if config is None:
            config = yaml.safe_load((path or HERE / "routing.yaml").read_text())
        self.cfg = config
        self._roles: dict[str, Role] = {}
        for name, spec in (config.get("roles") or {}).items():
            self._roles[name] = Role(
                name=name,
                model=spec["model"],
                family=spec["family"],
                cmd=tuple(spec["cmd"]),
                input=spec.get("input", "stdin"),
            )

    # --- roles ------------------------------------------------------------
    def role(self, name: str) -> Role:
        try:
            return self._roles[name]
        except KeyError:
            raise UnknownRole(f"no role {name!r} in routing.yaml") from None

    def family(self, name: str) -> str:
        return self.role(name).family

    def family_of_model(self, model: str) -> str | None:
        """Resolve a raw model string to a family via the glob table.

        Used when a verdict or ledger row carries a model name rather than a
        role — an upgraded model must still land in the right family.
        """
        for fam, patterns in (self.cfg.get("families") or {}).items():
            for pat in patterns:
                if fnmatch.fnmatch(model, pat):
                    return fam
        return None

    # --- independence -----------------------------------------------------
    def check_independence(self, judge_role: str, author_role: str) -> None:
        """Raise unless the judge is a different family than the author.

        This is the second hard rule. It is a raise, not a warning: a same-family
        judge produces a verdict that looks identical to a real one, so a soft
        failure here is worse than no check at all.
        """
        jf, af = self.family(judge_role), self.family(author_role)
        if jf == af:
            raise FamilyViolation(
                f"judge role {judge_role!r} ({jf}) shares a family with "
                f"author role {author_role!r} ({af})"
            )

    def check_all_independence(self) -> None:
        for judge_role, author_role in self.cfg.get("independence") or []:
            self.check_independence(judge_role, author_role)

    # --- escalation -------------------------------------------------------
    def escalation_ladder(self) -> list[dict[str, Any]]:
        return list((self.cfg.get("escalation") or {}).get("ladder") or [])

    def escalate(self, rung: int) -> dict[str, Any] | None:
        ladder = self.escalation_ladder()
        return ladder[rung] if 0 <= rung < len(ladder) else None

    def may_escalate(self, reason: str) -> bool:
        """Escalation is triggered by verify failure and nothing else.

        Not by a model reporting low confidence, not by elapsed time, not by an
        agent asking. Those are all things a failing worker can manufacture.
        """
        trigger = (self.cfg.get("escalation") or {}).get("trigger", "verify_failure_only")
        return reason == "verify_failure" if trigger == "verify_failure_only" else True

    # --- ceilings ---------------------------------------------------------
    def ceilings(self) -> dict[str, Any]:
        return dict(self.cfg.get("ceilings") or {})

    def blocking_ceilings(self) -> list[str]:
        return [k for k, v in self.ceilings().items() if v.get("action") == "block"]

    def validate(self) -> None:
        """Startup sanity. Called by `foreman init` and before `launch`."""
        self.check_all_independence()
        blocking = self.blocking_ceilings()
        if len(blocking) > 1:
            # Two blocking ceilings means a night can die for a reason nobody
            # chose, and the ledger cannot say which one was the real limit.
            raise ValueError(
                f"routing.yaml declares {len(blocking)} blocking ceilings "
                f"({', '.join(blocking)}); exactly one may block"
            )
        if not blocking:
            raise ValueError("routing.yaml declares no blocking ceiling")
        for name in ("executor", "planner", "judge", "plan_judge"):
            self.role(name)  # raises UnknownRole if missing

    def timeout(self, key: str = "role_seconds") -> int:
        return int((self.cfg.get("timeouts") or {}).get(key, 3600))

    def path(self, key: str) -> str:
        return (self.cfg.get("paths") or {})[key]
