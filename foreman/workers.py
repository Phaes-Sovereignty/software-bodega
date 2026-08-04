"""workers.py — one interface to every model, three adapters behind it.

    invoke(role, work_order) -> Result{files, status_block, usage, wall_s}

Everything upstream sees that signature and nothing else. The differences
between CLIs — and they are all sharp edges learned the hard way in Phase B —
are confined to the adapters:

- claude refuses tool use non-interactively without a permission mode
- claude's --allowedTools is variadic, so a trailing prompt argument is eaten
- grok rejects stdin and takes the prompt as an argument
- an argument-mode prompt must not start with '-', and every skill file opens
  with '---' YAML frontmatter
- macOS has no timeout(1)

Two structural rules live here rather than in prompts:

**Prompt assembly** is a frozen prefix plus a variable suffix. The prefix is
byte-identical across calls of the same role, which is what makes provider-side
caching work; anything task-specific goes in the suffix.

**Channel separation**: a judge or debugger never receives Implementation Notes
or a loop transcript. `WorkOrder.notes` is dropped for judging roles — not by
convention, by the code refusing to assemble them.
"""
from __future__ import annotations

import json
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .router import Router, Role

JUDGING_ROLES = {"judge", "plan_judge"}

STATUS_RE = re.compile(
    r"---FACTORY_STATUS---\s*\n(.*?)\n\s*---END---", re.DOTALL)

VALID_STATUSES = {"DONE", "BLOCKED", "NEEDS_CONTEXT"}


class AdapterError(Exception):
    pass


class ContractTestFailed(Exception):
    """An adapter did not honour the status-block contract at startup."""


@dataclass
class WorkOrder:
    prefix: str = ""            # frozen: skill text, contract, standing rules
    suffix: str = ""            # variable: this task, this diff, this receipt
    notes: str = ""             # Implementation Notes — never sent to a judge
    task_id: str = "-"
    station: str = "-"


@dataclass
class StatusBlock:
    station: str = ""
    task_id: str = ""
    status: str = ""
    summary: str = ""
    fields: dict[str, str] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.status in VALID_STATUSES and bool(self.station) and bool(self.summary)


@dataclass
class Result:
    role: str
    text: str
    status_block: StatusBlock | None
    usage: dict[str, int]
    wall_s: float
    returncode: int
    files: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and self.status_block is not None and self.status_block.ok


def parse_status_block(text: str) -> StatusBlock | None:
    """Take the LAST complete block: models often echo the template first."""
    matches = STATUS_RE.findall(text or "")
    if not matches:
        return None
    body = matches[-1]
    fields: dict[str, str] = {}
    for line in body.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        fields[k.strip().upper()] = v.strip()
    return StatusBlock(
        station=fields.get("STATION", ""),
        task_id=fields.get("TASK_ID", ""),
        status=fields.get("STATUS", ""),
        summary=fields.get("SUMMARY", ""),
        fields=fields,
    )


class Adapter:
    """Base adapter. Subclasses only normalise output and usage."""

    def __init__(self, role: Role, timeout: int = 3600):
        self.role = role
        self.timeout = timeout

    def build_argv(self, prompt: str) -> tuple[list[str], str | None]:
        """Return (argv, stdin_text)."""
        if self.role.input == "stdin":
            return list(self.role.cmd), prompt
        # An argument-mode prompt must not begin with a dash or the CLI's own
        # parser claims it as a flag and exits before the model sees anything.
        if prompt.startswith("-"):
            prompt = "\n" + prompt
        return [*self.role.cmd, prompt], None

    def normalise(self, raw: str) -> tuple[str, dict[str, int]]:
        return raw, {}

    def invoke(self, prompt: str) -> Result:
        argv, stdin_text = self.build_argv(prompt)
        t0 = time.time()
        try:
            proc = subprocess.run(
                argv, input=stdin_text, capture_output=True, text=True,
                timeout=self.timeout)
            rc, raw, err = proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired:
            return Result(self.role.name, "", None, {}, time.time() - t0, 124)
        except OSError as e:
            raise AdapterError(f"{self.role.name}: cannot execute {argv[0]!r}: {e}") from None
        wall = time.time() - t0
        if rc != 0:
            # Loud, not silent: an empty result three stations downstream is far
            # more expensive to debug than a failure at the adapter.
            raise AdapterError(
                f"{self.role.name} ({self.role.model}) exited {rc}: {(err or raw)[:300]}")
        text, usage = self.normalise(raw)
        return Result(self.role.name, text, parse_status_block(text), usage, wall, rc)


class ClaudeAdapter(Adapter):
    def normalise(self, raw: str) -> tuple[str, dict[str, int]]:
        try:
            env = json.loads(raw)
        except json.JSONDecodeError:
            return raw, {}
        u = env.get("usage") or {}
        return env.get("result", raw), {
            "tokens_in": int(u.get("input_tokens", 0) or 0)
            + int(u.get("cache_read_input_tokens", 0) or 0)
            + int(u.get("cache_creation_input_tokens", 0) or 0),
            "tokens_out": int(u.get("output_tokens", 0) or 0),
        }


class GrokAdapter(Adapter):
    pass  # plain text on stdout; no usage payload exposed


class CodexAdapter(Adapter):
    def normalise(self, raw: str) -> tuple[str, dict[str, int]]:
        # codex prints a banner and a "tokens used" line around the answer.
        m = re.search(r"tokens used[:\s]+([\d,]+)", raw, re.IGNORECASE)
        used = int(m.group(1).replace(",", "")) if m else 0
        return raw, {"tokens_in": 0, "tokens_out": used}


ADAPTERS = {"claude": ClaudeAdapter, "grok": GrokAdapter, "codex": CodexAdapter}


class Workers:
    def __init__(self, router: Router | None = None):
        self.router = router or Router()
        self._adapters: dict[str, Adapter] = {}

    def adapter(self, role_name: str) -> Adapter:
        if role_name not in self._adapters:
            role = self.router.role(role_name)
            cls = ADAPTERS.get(role.model, Adapter)
            self._adapters[role_name] = cls(role, self.router.timeout("role_seconds"))
        return self._adapters[role_name]

    # --- prompt assembly --------------------------------------------------
    def assemble(self, role_name: str, wo: WorkOrder) -> str:
        """Frozen prefix + variable suffix. Notes are dropped for judges.

        The drop is unconditional and happens here, so no prompt file has to
        remember it and no reviewer can be handed a worker's self-justification.
        """
        parts = [wo.prefix.rstrip(), wo.suffix.strip()]
        if wo.notes.strip() and role_name not in JUDGING_ROLES:
            parts.append("## Implementation Notes\n" + wo.notes.strip())
        return "\n\n".join(p for p in parts if p)

    # --- the one interface ------------------------------------------------
    def invoke(self, role_name: str, wo: WorkOrder) -> Result:
        return self.adapter(role_name).invoke(self.assemble(role_name, wo))

    # --- startup contract tests -------------------------------------------
    PROBE = (
        "Reply with ONLY this exact block and nothing else:\n"
        "---FACTORY_STATUS---\n"
        "STATION: probe\nTASK_ID: T00\nSTATUS: DONE\n"
        "SUMMARY: adapter reachable\n"
        "---END---"
    )

    def contract_test(self, role_name: str) -> Result:
        """A probe must come back with a parseable status block.

        Run before a night starts. An adapter that cannot honour the contract at
        1am could not have honoured it at 3am either — better to refuse now.
        """
        a = self.adapter(role_name)
        a_timeout, a.timeout = a.timeout, self.router.timeout("probe_seconds")
        try:
            res = a.invoke(self.PROBE)
        finally:
            a.timeout = a_timeout
        if res.status_block is None:
            raise ContractTestFailed(
                f"{role_name}: no FACTORY_STATUS block in the reply "
                f"(got {res.text[:120]!r})")
        if not res.status_block.ok:
            raise ContractTestFailed(
                f"{role_name}: malformed status block — "
                f"status={res.status_block.status!r} station={res.status_block.station!r}")
        return res

    def preflight(self, roles: list[str] | None = None) -> dict[str, str]:
        """Every adapter must pass before the night shift is allowed to start."""
        self.router.validate()
        roles = roles or ["executor", "planner", "judge", "plan_judge"]
        report: dict[str, str] = {}
        failures: list[str] = []
        for r in roles:
            try:
                res = self.contract_test(r)
                report[r] = f"ok ({self.router.family(r)}, {res.wall_s:.1f}s)"
            except (AdapterError, ContractTestFailed) as e:
                report[r] = f"FAILED: {e}"
                failures.append(r)
        if failures:
            raise ContractTestFailed(
                f"adapters failed preflight: {failures} — refusing to start the night")
        return report
