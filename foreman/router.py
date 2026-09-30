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
ROOT = HERE.parent

# Escalation lives in models.env, not routing.yaml. This is a narrow KEY=value
# reader — never a shell evaluator — for exactly three keys. The night shift is
# bash and cannot parse YAML without PyYAML, so the ladder has to live in a file
# it can read; Python then reads the SAME string rather than keeping a second
# copy that can drift.
LADDER_KEYS = ("ESCALATION_LADDER", "ESCALATION_TRIGGER", "JUDGE_ROLES")


def read_models_env(path: Path | None = None) -> dict[str, str]:
    f = Path(path) if path else ROOT / "models.env"
    out: dict[str, str] = {}
    if not f.exists():
        return out
    for line in f.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if k in LADDER_KEYS:
            out[k] = v
    return out


def parse_ladder(spec: str) -> list[dict[str, object]]:
    """`resample:executor:3:execution single:planner` -> rung dicts.

    Field order matches rung_field() in scripts/lib/status.sh: strategy, role,
    n, select. Anything missing falls back to the same defaults the shell uses.
    """
    rungs: list[dict[str, object]] = []
    for token in (spec or "").split():
        parts = token.split(":")
        rung: dict[str, object] = {"strategy": parts[0], "role": parts[1] if len(parts) > 1 else "executor"}
        if len(parts) > 2 and parts[2]:
            try:
                rung["n"] = int(parts[2])
            except ValueError:
                rung["n"] = parts[2]
        if len(parts) > 3 and parts[3]:
            rung["select"] = parts[3]
        rungs.append(rung)
    return rungs


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
    def __init__(self, config: dict[str, Any] | None = None, path: Path | None = None,
                 models_env: Path | None = None):
        if config is None:
            config = yaml.safe_load((path or HERE / "routing.yaml").read_text())
        self.cfg = config
        self.models = read_models_env(models_env)
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
        """The ladder from models.env, parsed.

        routing.yaml used to carry it and had no shell-readable twin, so
        nightshift.sh could not climb and Router.escalate() had no caller. If a
        routing.yaml still declares one, that is a second source of truth and it
        is REJECTED rather than silently preferred.
        """
        legacy = (self.cfg.get("escalation") or {}).get("ladder")
        if legacy:
            raise ValueError(
                "escalation ladder declared in routing.yaml AND models.env; "
                "delete the routing.yaml block — models.env is the single source")
        return parse_ladder(self.models.get("ESCALATION_LADDER", ""))

    def escalate(self, rung: int) -> dict[str, Any] | None:
        ladder = self.escalation_ladder()
        return ladder[rung] if 0 <= rung < len(ladder) else None

    def may_escalate(self, reason: str) -> bool:
        """Escalation is triggered by verify failure and nothing else.

        Not by a model reporting low confidence, not by elapsed time, not by an
        agent asking. Those are all things a failing worker can manufacture.
        Same rule as may_escalate() in scripts/lib/status.sh, same source string.
        """
        trigger = self.models.get("ESCALATION_TRIGGER", "verify_failure_only")
        return reason == "verify_failure" if trigger == "verify_failure_only" else True

    def judge_roles(self) -> list[str]:
        """Roles allowed to judge, in preference order (models.env: JUDGE_ROLES)."""
        return (self.models.get("JUDGE_ROLES") or "judge").split()

    def judge_for_family(self, author_families: str | list[str]) -> str:
        """Pick a judge whose family differs from EVERY family that wrote code.

        The mirror of judge_for_family() in the shell. Checking `judge` against
        `executor` once at startup is not enough: the author is whoever the
        escalation ladder actually used, and a same-family verdict is
        indistinguishable from a real one, which is worse than no verdict.
        Raises FamilyViolation when every judge role shares a family with an
        author — the caller must refuse, never fall back to self-grading.
        """
        if isinstance(author_families, str):
            authors = {a for a in author_families.replace(",", " ").split() if a}
        else:
            authors = {a for a in author_families if a}
        if not authors:
            raise FamilyViolation("judge_for_family: no authoring family given")
        for role in self.judge_roles():
            try:
                fam = self.family(role)
            except UnknownRole:
                continue
            if fam and fam not in authors:
                return role
        raise FamilyViolation(
            f"no judge role outside the authoring families {sorted(authors)}")

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
        # Every role models.env NAMES must exist here. JUDGE_ROLES and the ladder
        # are read by both consumers; a role the Python side does not know is a
        # candidate judge it silently skips, so the shell and the foreman would
        # disagree about who is available — and a missing ladder role means a
        # rung that can never fire.
        missing = []
        for role in self.judge_roles():
            if role not in self._roles:
                missing.append(f"JUDGE_ROLES:{role}")
        for rung in self.escalation_ladder():
            want = str(rung.get("role", ""))
            if want and want not in self._roles:
                missing.append(f"ladder:{want}")
        if missing:
            raise ValueError(
                "models.env names roles that routing.yaml does not define: "
                + ", ".join(sorted(set(missing))))

    def timeout(self, key: str = "role_seconds") -> int:
        return int((self.cfg.get("timeouts") or {}).get(key, 3600))
