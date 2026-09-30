"""gates.py — the mechanical gates. Pure functions, no model calls.

Every gate here is anchored to something a model cannot talk its way past: a
schema, a graph property, a subprocess exit code. The one judged gate
(`plan_review`) lives in workers/fsm because it needs an adapter; everything
else is arithmetic on artifacts.

Two rules run through all of them:

- **Missing evidence is never a pass.** A gate that could not run its check
  fails. Absence of a receipt is not a green receipt.
- **A gate returns findings, not a boolean.** "It failed" is not actionable;
  "AC-7 is covered by no task" is.
"""
from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "lib"))
import schemas  # noqa: E402

from .contracts import DEFAULT_HELDOUT, read_toolchain  # noqa: E402


@dataclass
class GateResult:
    gate: str
    passed: bool
    findings: list[str] = field(default_factory=list)
    detail: dict[str, Any] = field(default_factory=dict)

    def __bool__(self) -> bool:
        return self.passed

    @classmethod
    def ok(cls, gate: str, **detail: Any) -> "GateResult":
        return cls(gate, True, [], detail)

    @classmethod
    def fail(cls, gate: str, findings: list[str], **detail: Any) -> "GateResult":
        return cls(gate, False, findings, detail)


def _load(path: Path) -> tuple[Any, list[str]]:
    if not path.exists():
        return None, [f"{path} does not exist"]
    try:
        return json.loads(path.read_text()), []
    except json.JSONDecodeError as e:
        return None, [f"{path}: invalid JSON — {e}"]


# --- spec ------------------------------------------------------------------

def spec_gate(root: Path) -> GateResult:
    p = Path(root) / "factory/.planning/spec.json"
    doc, errs = _load(p)
    if errs:
        return GateResult.fail("spec", errs)
    errs = schemas.validate_spec(doc)
    criteria = doc.get("criteria") or []
    non_goals = doc.get("non_goals") or []
    if not criteria:
        errs.append("spec has no criteria")
    for c in criteria:
        if c.get("check") not in schemas.VALID_CHECKS:
            errs.append(f"{c.get('id','?')}: check kind {c.get('check')!r} is not test|type|cli")
    if not non_goals:
        # An empty non-goals list means the interview never bounded the work.
        # Everything is in scope, so nothing can be out of scope, so the
        # inspector can never call scope creep.
        errs.append("non_goals is empty — the interview did not bound the work")
    if errs:
        return GateResult.fail("spec", errs)
    return GateResult.ok("spec", criteria=len(criteria), non_goals=len(non_goals))


# --- decompose -------------------------------------------------------------

def _cycles(tasks: list[dict]) -> list[str]:
    adj = {t["id"]: list(t.get("depends") or []) for t in tasks if "id" in t}
    state: dict[str, int] = {}
    found: list[str] = []

    def visit(n: str, stack: list[str]) -> None:
        if state.get(n) == 2:
            return
        if state.get(n) == 1:
            found.append("cycle: " + " -> ".join(stack + [n]))
            return
        state[n] = 1
        for m in adj.get(n, []):
            if m in adj:
                visit(m, stack + [n])
        state[n] = 2

    for t in tasks:
        if "id" in t:
            visit(t["id"], [])
    return found


def decompose_gate(root: Path, context_cap: int = 100_000) -> GateResult:
    root = Path(root)
    dp = root / "factory/.planning/decompose.json"
    sp = root / "factory/.planning/spec.json"
    doc, errs = _load(dp)
    if errs:
        return GateResult.fail("decompose", errs)
    spec, serrs = _load(sp)
    if serrs:
        return GateResult.fail("decompose", serrs)

    errs = schemas.validate_decompose(doc)
    tasks = doc.get("tasks") or []
    errs += _cycles(tasks)

    # AC coverage in BOTH directions. One direction alone lets a task claim an
    # AC that does not exist, or an AC sit uncovered while every task looks busy.
    acs = {c["id"] for c in (spec.get("criteria") or []) if "id" in c}
    covered: set[str] = set()
    for t in tasks:
        covered |= set(t.get("exam_refs") or [])
    if acs - covered:
        errs.append(f"AC covered by no task: {sorted(acs - covered)}")
    if covered - acs:
        errs.append(f"exam_refs naming unknown ACs: {sorted(covered - acs)}")

    for t in tasks:
        ce = t.get("context_estimate", 0)
        if isinstance(ce, int) and ce >= context_cap:
            errs.append(f"{t.get('id','?')}: context_estimate {ce} >= cap {context_cap}")

    # dependency-ordered: a task must not depend on one declared after it
    order = {t["id"]: i for i, t in enumerate(tasks) if "id" in t}
    for t in tasks:
        for d in t.get("depends") or []:
            if d in order and order[d] > order.get(t["id"], 0):
                errs.append(f"{t['id']} depends on {d}, which is declared later")

    if errs:
        return GateResult.fail("decompose", errs)
    return GateResult.ok("decompose", tasks=len(tasks), acs=len(acs))


# --- design records --------------------------------------------------------

def design_record_gate(root: Path) -> GateResult:
    root = Path(root)
    doc, errs = _load(root / "factory/.planning/decompose.json")
    if errs:
        return GateResult.fail("design_record", errs)
    errs = []
    high = [t for t in (doc.get("tasks") or []) if t.get("risk") == "high"]
    for t in high:
        adr = t.get("adr")
        if not adr:
            errs.append(f"{t.get('id','?')}: risk=high but no adr linked")
            continue
        p = root / "factory/adr" / f"{adr}.md"
        if not p.exists():
            errs.append(f"{t.get('id','?')}: adr {adr} linked but {p} is missing")
        elif not p.read_text().strip():
            errs.append(f"{t.get('id','?')}: adr {adr} is empty")
    if errs:
        return GateResult.fail("design_record", errs)
    return GateResult.ok("design_record", high_risk_tasks=len(high))


# --- plan ------------------------------------------------------------------

def plan_gate(root: Path) -> GateResult:
    root = Path(root)
    doc, errs = _load(root / "factory/.planning/plan.json")
    if errs:
        return GateResult.fail("plan", errs)
    errs = schemas.validate_plan(doc)
    slices = doc.get("slices") or []
    if not slices:
        errs.append("plan has no slices")

    # A weak qualifier is not a failure — it is a routing signal. Record the
    # tier bump so the ledger shows why a slice ran on a stronger model.
    bumps = [s.get("plan_id", "?") for s in slices if s.get("qualifier") == "weak"]

    # A manifest must stay inside its task's declared boundary.
    dec, _ = _load(root / "factory/.planning/decompose.json")
    if isinstance(dec, dict):
        bounds = {t.get("id"): set(t.get("boundary") or []) for t in (dec.get("tasks") or [])}
        for s in slices:
            tid = str(s.get("plan_id", "")).removeprefix("P-")
            if tid in bounds and bounds[tid]:
                manifest = set((s.get("grounds") or {}).get("file_manifest") or [])
                outside = manifest - bounds[tid]
                if outside:
                    errs.append(f"{s.get('plan_id')}: manifest outside {tid} boundary: {sorted(outside)}")

    if errs:
        return GateResult.fail("plan", errs, tier_bumps=bumps)
    return GateResult.ok("plan", slices=len(slices), tier_bumps=bumps)


# --- exams -----------------------------------------------------------------

def _run(cmd: list[str], cwd: Path, timeout: int) -> tuple[int, str]:
    try:
        r = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr)
    except subprocess.TimeoutExpired:
        return 124, "TIMEOUT"
    except OSError as e:
        return 127, f"could not execute: {e}"


DEFAULT_RUNNERS = {"visible": "factory/tests/run-visible.sh",
                   "heldout": "factory/tests/run-heldout.sh"}


def suite_command(root: Path, kind: str) -> tuple[str, str | None]:
    """Resolve the command that runs a suite, from the PROJECT's toolchain.

    Returns (command, missing_path). `missing_path` is non-None only when the
    command is the default runner script and that script does not exist — which
    is missing evidence, and a gate must fail on missing evidence rather than
    report a 127 as though a test had run.

    Before this, exam_gate/heldout_gate took a runner PATH with a hard-coded
    default, so a Swift project — whose suites are `swift test --filter …` —
    either failed the gate for lacking a shell script it should never have
    needed, or was checked by a script that verified nothing.
    """
    tc = read_toolchain(Path(root))
    cmd = (tc.get(f"{kind.upper()}_CMD") or "").strip()
    if not cmd:
        runner = DEFAULT_RUNNERS[kind]
        if not (Path(root) / runner).exists():
            return f"bash {runner}", runner
        return f"bash {runner}", None
    return cmd, None


def _run_shell(cmd: str, cwd: Path, timeout: int) -> tuple[int, str]:
    try:
        r = subprocess.run(["bash", "-c", cmd], cwd=str(cwd), capture_output=True,
                           text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr)
    except subprocess.TimeoutExpired:
        return 124, "TIMEOUT"
    except OSError as e:
        return 127, f"could not execute: {e}"


def exam_gate(root: Path, runner: str | None = None,
              timeout: int = 1800, runs: int = 2) -> GateResult:
    """Run the visible suite TWICE. A flaky green is a finding, not a pass.

    The foreman runs this itself rather than believing a reported result — the
    exit code is the evidence, and it is only evidence if we produced it.

    The command is the project's VISIBLE_CMD when it declares one, so a Swift
    night is gated on `swift test --filter VisibleTests` and not on a shell
    script the project does not have.
    """
    root = Path(root)
    cmd, missing = (f"bash {runner}", None if (root / runner).exists() else runner) \
        if runner else suite_command(root, "visible")
    if missing:
        # Missing evidence is not a pass.
        return GateResult.fail("exam", [f"no visible runner at {missing} — cannot prove green"])

    codes, logs = [], []
    for _ in range(runs):
        rc, out = _run_shell(cmd, root, timeout)
        codes.append(rc)
        logs.append(out[-4000:])

    if len(set(codes)) > 1:
        return GateResult.fail(
            "exam",
            [f"FLAKY: visible suite disagreed with itself across {runs} runs: exits {codes}"],
            exits=codes, log=logs[-1])
    if codes[0] != 0:
        return GateResult.fail("exam", [f"visible suite failed: exit {codes[0]}"],
                               exits=codes, log=logs[-1])
    return GateResult.ok("exam", exits=codes, runs=runs)


def heldout_gate(root: Path, runner: str | None = None,
                 timeout: int = 1800) -> GateResult:
    """Run the HELD-OUT suite. Never from a sealed tree — the files are gone there.

    This is the gate that did not exist in the night path at all: HELDOUT_CMD was
    declared and read by nobody, so the mechanism the whole design rests on was
    Python-only by accident.
    """
    root = Path(root)
    cmd, missing = (f"bash {runner}", None if (root / runner).exists() else runner) \
        if runner else suite_command(root, "heldout")
    if missing:
        return GateResult.fail("heldout", [f"no held-out runner at {missing} — cannot prove green"])
    hdir = read_toolchain(root).get("HELDOUT_DIR") or DEFAULT_HELDOUT
    if not (root / hdir).is_dir():
        return GateResult.fail(
            "heldout",
            [f"held-out suite directory {hdir} is absent — cannot prove the held-out checks ran"])
    rc, out = _run_shell(cmd, root, timeout)
    if rc != 0:
        return GateResult.fail("heldout", [f"held-out suite failed: exit {rc}"],
                               exit=rc, log=out[-4000:])
    return GateResult.ok("heldout", exit=rc, command=cmd, heldout_dir=hdir)


ALL_GATES = {
    "spec": spec_gate,
    "decompose": decompose_gate,
    "design_record": design_record_gate,
    "plan": plan_gate,
    "exam": exam_gate,
    "heldout": heldout_gate,
}
