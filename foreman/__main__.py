"""foreman — the bootstrap pipeline's authority.

    python -m foreman init      validate routing, probe every adapter
    python -m foreman status    where the line is and what is blocking it
    python -m foreman gate <id> run a gate, record the verdict, transition
    python -m foreman launch    run the night shift under foreman authority
    python -m foreman resume    continue after a crash or a BLOCKED state
    python -m foreman debrief    morning summary + one webhook

The foreman owns station transitions. It does NOT own the night loop: it invokes
scripts/nightshift.sh, which keeps its own semantics. The Small Loop
(runner.sh + CI) is untouched by design.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

from . import gates as G
from . import steps as S
from .breakers import Breakers
from .contracts import Store, Verdict, create_sealed_worktree, remove_worktree
from .fsm import FSM, REQUIRED, GateNotPassed, IllegalTransition
from .ledger import CeilingExceeded, Ledger
from .notify import Notifier
from .router import FamilyViolation, Router
from .workers import ContractTestFailed, Workers, AdapterError

GATE_TO_ARTIFACT = {
    "spec": "spec",
    "decompose": "decompose",
    "design_record": "decompose",
    "plan": "plan",
    "plan_review": "plan",
    "exam": "spec",      # the exam gate is about the suites; bind it to the spec
    "brief": "spec",
}


def _root(args) -> Path:
    return Path(args.root).resolve()


def _bootstrap(args):
    root = _root(args)
    router = Router()
    store = Store(root)
    S.configure(root, enabled=not getattr(args, "no_memo", False))
    return root, router, store, FSM(root, store), Ledger(root, router.ceilings()), \
        Breakers(root), Notifier(root, getattr(args, "webhook", None))


# --- commands --------------------------------------------------------------

def cmd_init(args) -> int:
    root, router, store, fsm, ledger, br, note = _bootstrap(args)
    for d in ("factory/.planning/gate-results", "factory/.steps", "factory/tasks",
              "factory/tests/visible", "factory/tests/heldout"):
        (root / d).mkdir(parents=True, exist_ok=True)
    print(f"foreman init — {root}")
    try:
        router.validate()
        print("  routing.yaml: valid")
        for j, a in router.cfg.get("independence", []):
            print(f"    {j} ({router.family(j)}) != {a} ({router.family(a)})")
        print(f"    blocking ceiling: {router.blocking_ceilings()[0]}")
    except (FamilyViolation, ValueError) as e:
        print(f"  routing.yaml: INVALID — {e}")
        return 1
    if args.probe:
        print("  adapter contract tests:")
        w = Workers(router)
        try:
            for role, status in w.preflight().items():
                print(f"    {role:11s} {status}")
        except ContractTestFailed as e:
            # Print per-role results BEFORE the summary: "something failed" with
            # no reason is the least useful possible output from a preflight.
            for role in w.REQUIRED_ROLES + w.OPTIONAL_ROLES:
                if role in getattr(e, "report", {}):
                    print(f"    {role:11s} {e.report[role]}")
            print(f"    -> {e}")
            return 1
        except AdapterError as e:
            print(f"    {e}")
            return 1
    if not (root / "factory/STATE.md").exists():
        fsm._write_state("INTERVIEW", "initialised")
    print(f"  station: {fsm.station()}")
    return 0


def cmd_status(args) -> int:
    root, router, store, fsm, ledger, br, note = _bootstrap(args)
    station = fsm.station()
    print(f"station : {station}")
    print(f"pointer : {fsm.pointer()}")

    live = store.live_shas()
    print("artifacts:")
    for kind in ("spec", "decompose", "plan"):
        p = store.path_for(kind)
        if not p.exists():
            print(f"  {kind:10s} —")
            continue
        errs = store.validate(kind)
        from .contracts import content_sha
        print(f"  {kind:10s} {content_sha(p)[:12]}  {'valid' if not errs else f'INVALID ({len(errs)})'}")

    req = REQUIRED.get(station, ())
    if req:
        print(f"gates for {station}:")
        for g in req:
            sha = _sha_for_gate(store, g)
            v = store.verdict(g, sha) if sha else None
            mark = "PASS" if (v and v.passed) else ("FAIL" if v else "—")
            print(f"  {g:14s} {mark:5s} {('@' + sha[:12]) if sha else ''}")

    t = ledger.totals()
    ceil = router.ceilings()
    print(f"ledger  : {t['entries']} rows, {t['rounds']} rounds "
          f"(limit {ceil['rounds']['limit']}, blocking), "
          f"{t['tokens']:,} tokens (limit {ceil['tokens']['limit']:,}, warn only), "
          f"{t['wall_s'] / 60:.0f} min")
    b = br.summary()
    print(f"breakers: parks={b['parks']} empty_diffs={b['empty_diffs']} "
          f"open={b['open']}" + (f" ({b['reason']}, {b['cooldown_s']}s cooldown)" if b['open'] else ""))
    st = S.summary(root)
    print(f"steps   : {len(st)} memoized")
    stale = [p.name for p in store.gate_dir.glob("*.json")
             if p.stem.rsplit("-", 1)[-1] not in live]
    if stale:
        print(f"stale   : {len(stale)} verdict(s) not bound to a live artifact "
              f"(run `foreman gate --gc`)")
    return 0


def _sha_for_gate(store: Store, gate: str) -> str | None:
    kind = GATE_TO_ARTIFACT.get(gate)
    if not kind:
        return None
    p = store.path_for(kind)
    if not p.exists():
        return None
    from .contracts import content_sha
    return content_sha(p)


def cmd_gate(args) -> int:
    root, router, store, fsm, ledger, br, note = _bootstrap(args)
    if args.gc:
        removed = store.gc(store.live_shas())
        print(f"discarded {len(removed)} stale verdict(s)")
        return 0
    gate = args.gate
    if gate not in G.ALL_GATES and gate != "plan_review":
        print(f"unknown gate {gate!r}; known: {sorted(G.ALL_GATES) + ['plan_review']}")
        return 2

    sha = _sha_for_gate(store, gate)
    if sha is None:
        print(f"cannot bind {gate}: its artifact does not exist yet")
        return 1

    t0 = time.time()
    if gate == "plan_review":
        res = _plan_review(root, router, store, ledger)
    else:
        fn = G.ALL_GATES[gate]
        res = fn(root)
        store.record(Verdict(gate=gate, sha=sha, verdict="PASS" if res.passed else "FAIL",
                             passed=res.passed, detail="; ".join(res.findings)[:500]))
    ledger.record(station=fsm.station(), role="foreman", note=f"gate:{gate}",
                  wall_s=round(time.time() - t0, 2))

    print(f"{gate}: {'PASS' if res.passed else 'FAIL'} @ {sha[:12]}")
    for f in res.findings:
        print(f"  - {f}")
    if not res.passed:
        return 1

    if args.no_transition:
        return 0
    try:
        t = fsm.fire(gate, sha)
        print(f"transition: {t.frm} --{gate}--> {t.to}")
    except (IllegalTransition, GateNotPassed) as e:
        print(f"no transition: {e}")
    return 0


def _plan_review(root: Path, router: Router, store: Store, ledger: Ledger):
    """The one judged gate. Cross-family, artifact-only, SHA-bound."""
    from .workers import WorkOrder
    router.check_independence("plan_judge", "planner")
    sha = _sha_for_gate(store, "plan")
    plan = (root / "factory/.planning/plan.json").read_text()
    contract_p = root / "factory/CONTRACT.md"
    contract = contract_p.read_text() if contract_p.exists() else ""
    wo = WorkOrder(
        prefix=("You are reviewing a work-order plan. Artifact-only: you get the plan\n"
                "and the contract, no transcript and no implementation notes.\n\n"
                "Check each slice: does the warrant actually support the claim? Is any\n"
                "slice marked strong that should be weak? Is any rebuttal missing a real\n"
                "failure mode? Is the file manifest inside the task boundary?\n"),
        suffix=(f"Your FIRST LINE must be exactly:\n"
                f"Verdict on plan@{sha}: APPROVE | APPROVE WITH NOTES | REJECT\n\n"
                f"===== PLAN =====\n{plan}\n\n===== CONTRACT =====\n{contract}\n"),
    )
    res = Workers(router).invoke("plan_judge", wo)
    ledger.record(station="WORKORDER", role="plan_judge",
                  model=router.role("plan_judge").model, rounds=1,
                  wall_s=round(res.wall_s, 2), **{"note": "plan_review"})
    text = res.text or ""
    approved = "REJECT" not in text.split("\n")[0].upper() and "APPROVE" in text.upper()
    verdict_line = next((l for l in text.splitlines() if l.strip().startswith("Verdict on")), "")
    store.record(Verdict(gate="plan_review", sha=sha, verdict=verdict_line[:200],
                         passed=approved, judge_family=router.family("plan_judge"),
                         author_family=router.family("planner"),
                         detail=text[:1000]))
    return G.GateResult("plan_review", approved,
                        [] if approved else [verdict_line or "rejected"])


def cmd_launch(args) -> int:
    root, router, store, fsm, ledger, br, note = _bootstrap(args)
    if br.is_open:
        print(f"breaker OPEN ({br.state.open_reason}); "
              f"{br.cooldown_remaining():.0f}s of cooldown left")
        return 1
    try:
        report = Workers(router).preflight() if args.probe else {}
        for r, s in report.items():
            print(f"  {r:11s} {s}")
    except (ContractTestFailed, AdapterError) as e:
        print(f"preflight failed: {e}")
        note.stop(f"preflight failed: {e}")
        return 1

    # Seal the night: the worker sandbox has no held-out tests on disk.
    wt = None
    if args.sealed:
        wt = root / ".foreman-sandbox"
        remove_worktree(root, wt)
        try:
            create_sealed_worktree(root, wt, heldout=router.path("heldout"))
            print(f"sealed sandbox: {wt} (held-out physically absent)")
        except Exception as e:
            print(f"sealing failed: {e}")
            return 1

    workdir = wt or root
    t0 = time.time()
    rc = subprocess.call(["bash", str(root / "scripts/nightshift.sh"),
                          "--max-iters", str(args.max_iters)], cwd=str(workdir))
    ledger.record(station="NIGHT_SHIFT", role="executor",
                  model=router.role("executor").model, rounds=1,
                  wall_s=round(time.time() - t0, 2), note=f"nightshift rc={rc}")
    try:
        for w in ledger.check():
            print(f"  warning: {w}")
    except CeilingExceeded as e:
        print(f"  {e}")
        note.stop(str(e))
        br.trip(str(e))
        return 1
    if wt and not args.keep_sandbox:
        print("sandbox left in place for inspection" if rc else "removing sandbox")
        if not rc:
            remove_worktree(root, wt)
    return rc


def cmd_resume(args) -> int:
    root, router, store, fsm, ledger, br, note = _bootstrap(args)
    if fsm.station() == "BLOCKED":
        to = fsm.resume(args.station)
        print(f"resumed: BLOCKED -> {to}")
    else:
        print(f"not blocked; station is {fsm.station()}")
    done = S.summary(root)
    print(f"{len(done)} completed step(s) will be skipped on replay:")
    for s in done[-8:]:
        print(f"  {s['step_id']:24s} {s['input_sha']}  {s['ts']}")
    if br.state.opened_at and br.may_retry():
        print("breaker half-open: one retry allowed")
    return 0


def cmd_debrief(args) -> int:
    root, router, store, fsm, ledger, br, note = _bootstrap(args)
    t = ledger.totals()
    prog = root / "factory/progress.md"
    done = parked = 0
    if prog.exists():
        for line in prog.read_text().splitlines():
            if "|DONE|" in line:
                done += 1
            elif "|PARKED|" in line:
                parked += 1
    review = root / "factory/REVIEW.md"
    verdict = review.read_text().splitlines()[0] if review.exists() else "(no inspection yet)"
    lines = [
        f"station     : {fsm.station()}",
        f"tasks       : {done} done, {parked} parked",
        f"verdict     : {verdict}",
        f"ledger      : {t['rounds']} rounds, {t['tokens']:,} tokens, {t['wall_s']/60:.0f} min",
        f"by role     : " + ", ".join(f"{k}={v['rounds']}r" for k, v in ledger.by_role().items() if k != "-"),
        f"breakers    : {json.dumps(br.summary())}",
    ]
    body = "\n".join(lines)
    print(body)
    if args.notify:
        ok = note.debrief(body, station=fsm.station(), done=done, parked=parked)
        print(f"webhook: {'delivered' if ok else 'journalled only (no URL or delivery failed)'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="foreman", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", default=".", help="factory repo root")
    p.add_argument("--no-memo", action="store_true", help="disable durable-step memoization")
    sub = p.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("init"); q.add_argument("--probe", action="store_true",
                                               help="run adapter contract tests"); q.set_defaults(fn=cmd_init)
    q = sub.add_parser("status"); q.set_defaults(fn=cmd_status)
    q = sub.add_parser("gate"); q.add_argument("gate", nargs="?", default="")
    q.add_argument("--gc", action="store_true", help="discard stale verdicts")
    q.add_argument("--no-transition", action="store_true")
    q.set_defaults(fn=cmd_gate)
    q = sub.add_parser("launch")
    q.add_argument("--max-iters", type=int, default=25)
    q.add_argument("--probe", action="store_true", default=True)
    q.add_argument("--no-probe", dest="probe", action="store_false")
    q.add_argument("--sealed", action="store_true", default=True,
                   help="run the night in a worktree with held-out tests absent")
    q.add_argument("--unsealed", dest="sealed", action="store_false")
    q.add_argument("--keep-sandbox", action="store_true")
    q.add_argument("--webhook", default=None)
    q.set_defaults(fn=cmd_launch)
    q = sub.add_parser("resume"); q.add_argument("--station", default=None); q.set_defaults(fn=cmd_resume)
    q = sub.add_parser("debrief"); q.add_argument("--notify", action="store_true")
    q.add_argument("--webhook", default=None); q.set_defaults(fn=cmd_debrief)

    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except (FamilyViolation, ContractTestFailed, AdapterError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
