"""Phase C definition-of-done tests.

    python3 -m unittest discover -s foreman/tests -v

Fixtures under fixtures/ are derived from the Phase B dry run's real artifacts,
so the PASS cases are things the factory actually produced and the FAIL cases
are single, deliberate mutations of them.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))

from foreman import gates as G                                    # noqa: E402
from foreman import steps as S                                    # noqa: E402
from foreman.breakers import Breakers                             # noqa: E402
from foreman.contracts import (Store, Verdict, content_sha,       # noqa: E402
                               create_sealed_worktree, verify_seal,
                               remove_worktree, SealError)
from foreman.fsm import (FSM, TRANSITIONS, STATIONS, REQUIRED,    # noqa: E402
                         IllegalTransition, GateNotPassed)
from foreman.ledger import Ledger, CeilingExceeded                # noqa: E402
from foreman.router import (Router, FamilyViolation, parse_ladder,   # noqa: E402
                           read_models_env)
from foreman.workers import (Workers, WorkOrder, parse_status_block,  # noqa: E402
                             ContractTestFailed, Adapter)

FIX = Path(__file__).resolve().parent / "fixtures"


def _repo(tmp: Path) -> Path:
    """A minimal factory repo with the planning artifacts in place."""
    (tmp / "factory/.planning/gate-results").mkdir(parents=True)
    (tmp / "factory/adr").mkdir(parents=True)
    (tmp / "factory/tests/visible").mkdir(parents=True)
    (tmp / "factory/tests/heldout").mkdir(parents=True)
    return tmp


def _install(tmp: Path, kind: str, fixture: str) -> None:
    shutil.copy(FIX / fixture, tmp / f"factory/.planning/{kind}.json")


# ---------------------------------------------------------------- FSM ------

class TestFSM(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.root = _repo(Path(self.td))
        self.store = Store(self.root)
        self.fsm = FSM(self.root, self.store)

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_every_illegal_transition_is_rejected(self):
        """Table-driven: every (station, gate) pair NOT in the table must raise."""
        gates = sorted({g for (_, g) in TRANSITIONS} | {"nonsense", "merge"})
        checked = 0
        for station in STATIONS:
            for gate in gates:
                if (station, gate) in TRANSITIONS:
                    continue
                self.fsm._write_state(station, "t")
                with self.assertRaises(IllegalTransition,
                                       msg=f"({station},{gate}) should be illegal"):
                    self.fsm.fire(gate, "deadbeef")
                checked += 1
        self.assertGreater(checked, 30)

    def test_legal_transition_requires_a_pass_verdict(self):
        self.fsm._write_state("SPEC", "t")
        with self.assertRaises(GateNotPassed):
            self.fsm.fire("spec", "aaa111")                 # no verdict at all
        self.store.record(Verdict(gate="spec", sha="aaa111", verdict="FAIL", passed=False))
        with self.assertRaises(GateNotPassed):
            self.fsm.fire("spec", "aaa111")                 # verdict says fail
        self.store.record(Verdict(gate="spec", sha="aaa111", verdict="PASS", passed=True))
        self.assertEqual(self.fsm.fire("spec", "aaa111").to, "BLUEPRINT")

    def test_verdict_for_another_sha_does_not_open_the_gate(self):
        self.store.record(Verdict(gate="spec", sha="aaa111", verdict="PASS", passed=True))
        self.fsm._write_state("SPEC", "t")
        with self.assertRaises(GateNotPassed):
            self.fsm.fire("spec", "bbb222")

    def test_verdict_predating_station_entry_is_stale(self):
        old = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7200))
        self.store.record(Verdict(gate="spec", sha="ccc333", verdict="PASS",
                                  passed=True, ts=old))
        self.fsm._write_state("SPEC", "t")                  # entered now
        with self.assertRaises(GateNotPassed) as cm:
            self.fsm.fire("spec", "ccc333")
        self.assertIn("predates", str(cm.exception))

    def test_leaving_a_station_requires_all_its_gates(self):
        self.fsm._write_state("BLUEPRINT", "t")
        self.store.record(Verdict(gate="decompose", sha="d1", verdict="PASS", passed=True))
        with self.assertRaises(GateNotPassed):
            self.fsm.fire("decompose", "d1")                # design_record missing
        self.store.record(Verdict(gate="design_record", sha="d1", verdict="PASS", passed=True))
        self.assertEqual(self.fsm.fire("decompose", "d1").to, "EXAM")

    def test_blocked_requires_a_reason_and_is_resumable(self):
        self.fsm._write_state("EXAM", "t")
        with self.assertRaises(ValueError):
            self.fsm.block("   ")
        self.fsm.block("held-out runner missing")
        self.assertEqual(self.fsm.station(), "BLOCKED")
        self.assertIn("held-out", self.fsm.pointer())
        self.assertEqual(self.fsm.resume(), "EXAM")

    def test_every_station_with_required_gates_can_reach_them(self):
        for station, req in REQUIRED.items():
            for gate in req:
                self.assertIn((station, gate), TRANSITIONS,
                              f"{station} requires {gate} but no transition uses it")


# -------------------------------------------------------------- gates ------

class TestGates(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.root = _repo(Path(self.td))
        _install(self.root, "spec", "_spec.json")
        _install(self.root, "decompose", "_decompose.json")

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_spec_gate_three_pass(self):
        for f in ("spec.pass1.json", "spec.pass2.json", "spec.pass3.json"):
            _install(self.root, "spec", f)
            self.assertTrue(G.spec_gate(self.root).passed, f)

    def test_spec_gate_three_fail(self):
        for f in ("spec.fail_no_nongoals.json", "spec.fail_bad_check.json",
                  "spec.fail_missing_check.json"):
            _install(self.root, "spec", f)
            r = G.spec_gate(self.root)
            self.assertFalse(r.passed, f)
            self.assertTrue(r.findings, f"{f} failed with no explanation")

    def test_decompose_gate_three_pass(self):
        for f in ("decompose.pass1.json", "decompose.pass2.json", "decompose.pass3.json"):
            _install(self.root, "decompose", f)
            r = G.decompose_gate(self.root)
            self.assertTrue(r.passed, f"{f}: {r.findings}")

    def test_decompose_gate_three_fail(self):
        for f, needle in (("decompose.fail_cycle.json", "cycle"),
                          ("decompose.fail_unknown_ac.json", "unknown"),
                          ("decompose.fail_uncovered.json", "covered by no task")):
            _install(self.root, "decompose", f)
            r = G.decompose_gate(self.root)
            self.assertFalse(r.passed, f)
            self.assertTrue(any(needle in x for x in r.findings),
                            f"{f}: findings did not mention {needle!r}: {r.findings}")

    def test_plan_gate_three_pass_three_fail(self):
        for f in ("plan.pass1.json", "plan.pass2.json", "plan.pass3.json"):
            _install(self.root, "plan", f)
            self.assertTrue(G.plan_gate(self.root).passed, f)
        for f in ("plan.fail_no_rebuttal.json", "plan.fail_bad_qualifier.json",
                  "plan.fail_no_warrant.json"):
            _install(self.root, "plan", f)
            r = G.plan_gate(self.root)
            self.assertFalse(r.passed, f)

    def test_plan_gate_records_tier_bumps_for_weak_slices(self):
        _install(self.root, "plan", "plan.pass1.json")
        r = G.plan_gate(self.root)
        self.assertTrue(r.detail.get("tier_bumps"), "weak slices must record a tier bump")

    def test_design_record_gate_requires_an_adr_that_exists(self):
        _install(self.root, "decompose", "_decompose.json")
        d = json.loads((self.root / "factory/.planning/decompose.json").read_text())
        for t in d["tasks"]:
            if t.get("risk") == "high":
                t["adr"] = "ADR-nonexistent"
        (self.root / "factory/.planning/decompose.json").write_text(json.dumps(d))
        r = G.design_record_gate(self.root)
        self.assertFalse(r.passed)
        self.assertTrue(any("missing" in f for f in r.findings))

    def test_exam_gate_missing_runner_is_not_a_pass(self):
        r = G.exam_gate(self.root)
        self.assertFalse(r.passed)
        self.assertIn("cannot prove green", r.findings[0])

    def test_exam_gate_runs_twice_and_flags_flaky(self):
        runner = self.root / "factory/tests/run-visible.sh"
        counter = self.root / ".flaky-counter"
        runner.write_text(
            "#!/usr/bin/env bash\n"
            f'n=$(cat "{counter}" 2>/dev/null || echo 0); echo $((n+1)) > "{counter}"\n'
            'if [ "$n" = "0" ]; then exit 0; else exit 1; fi\n')
        runner.chmod(0o755)
        r = G.exam_gate(self.root)
        self.assertFalse(r.passed, "a suite that flips must not pass")
        self.assertIn("FLAKY", r.findings[0])

    def test_exam_gate_passes_on_a_stable_green_suite(self):
        runner = self.root / "factory/tests/run-visible.sh"
        runner.write_text("#!/usr/bin/env bash\nexit 0\n")
        runner.chmod(0o755)
        self.assertTrue(G.exam_gate(self.root).passed)


# ------------------------------------------------------------- router ------

class TestRouter(unittest.TestCase):
    def test_declared_independence_holds(self):
        Router().validate()

    def test_same_family_judge_raises(self):
        r = Router()
        with self.assertRaises(FamilyViolation):
            r.check_independence("judge", "planner")   # both anthropic

    def test_cross_family_pairs_pass(self):
        r = Router()
        r.check_independence("judge", "executor")
        r.check_independence("plan_judge", "planner")

    def test_two_blocking_ceilings_is_a_config_error(self):
        r = Router()
        cfg = dict(r.cfg)
        cfg["ceilings"] = {"rounds": {"limit": 1, "action": "block"},
                           "tokens": {"limit": 1, "action": "block"}}
        with self.assertRaises(ValueError):
            Router(config=cfg).validate()

    def test_escalation_only_on_verify_failure(self):
        r = Router()
        self.assertTrue(r.may_escalate("verify_failure"))
        for excuse in ("low_confidence", "slow", "agent_requested"):
            self.assertFalse(r.may_escalate(excuse))

    # --- the ladder must be ONE source, and Python must actually read it -----
    # It used to live only in routing.yaml, which nightshift.sh cannot parse, so
    # the ladder was dead config: Router.escalate() had no caller and every
    # parked task parked at rung 0.

    def test_ladder_is_read_from_models_env(self):
        r = Router()
        ladder = r.escalation_ladder()
        self.assertGreaterEqual(len(ladder), 4,
                                "escalation ladder is empty — models.env is not being read")
        self.assertEqual(ladder[0]["strategy"], "resample")
        self.assertEqual(ladder[0]["n"], 3)
        self.assertEqual(ladder[0]["select"], "execution")
        self.assertEqual([x["role"] for x in ladder[1:]], ["planner", "plan_judge", "fallback"])

    def test_routing_yaml_cannot_declare_a_second_ladder(self):
        r = Router()
        cfg = dict(r.cfg)
        cfg["escalation"] = {"ladder": [{"strategy": "single", "role": "executor"}]}
        with self.assertRaises(ValueError):
            Router(config=cfg).escalation_ladder()

    def test_ladder_agrees_with_the_shell_string(self):
        """Both readers parse the SAME models.env line; a drift is a bug."""
        import re, subprocess
        spec = Router().models["ESCALATION_LADDER"]
        rungs = parse_ladder(spec)
        shell = subprocess.run(
            ["bash", "-c",
             'SRC="$1"; . "$SRC/scripts/lib/status.sh"; '
             'for i in $(seq 0 $(( $(ladder_length) - 1 ))); do '
             '  r="$(ladder_rung $i)"; printf "%s:%s\n" "$(rung_field "$r" 1)" "$(rung_field "$r" 2)"; '
             'done', "_", str(ROOT)],
            capture_output=True, text=True, check=True).stdout.strip().splitlines()
        py = [f"{x['strategy']}:{x['role']}" for x in rungs]
        self.assertEqual(py, shell, "Python and shell disagree about the ladder")

    def test_judge_roles_come_from_the_same_file(self):
        self.assertEqual(Router().judge_roles(),
                         Router().models["JUDGE_ROLES"].split())

    # --- judge selection against the family that ACTUALLY wrote the code -----

    def test_judge_for_family_picks_a_different_family(self):
        r = Router()
        self.assertEqual(r.judge_for_family(r.family("executor")), "judge")
        # anthropic authors (planner, and the judge role) must not be judged by
        # the judge role — that is the "Opus fixes, Opus judges" bug.
        self.assertNotEqual(r.judge_for_family("anthropic"), "judge")
        self.assertNotEqual(r.family(r.judge_for_family("anthropic")), "anthropic")

    def test_judge_for_family_honours_every_author(self):
        r = Router()
        role = r.judge_for_family("xai,anthropic")
        self.assertNotIn(r.family(role), {"xai", "anthropic"})

    def test_judge_for_family_refuses_instead_of_self_grading(self):
        """Every judge family authored -> raise. Falling back would grade itself."""
        r = Router()
        authors = [r.family(role) for role in r.judge_roles()]
        with self.assertRaises(FamilyViolation):
            r.judge_for_family(authors)

    def test_judge_for_family_rejects_an_empty_author_set(self):
        with self.assertRaises(FamilyViolation):
            Router().judge_for_family([])


# ------------------------------------------------------------- ledger ------

class TestLedger(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.root = Path(self.td)

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_rounds_ceiling_blocks(self):
        lg = Ledger(self.root, {"rounds": {"limit": 3, "action": "block"}})
        for _ in range(2):
            lg.record(rounds=1)
        lg.check()
        lg.record(rounds=1)
        with self.assertRaises(CeilingExceeded):
            lg.check()

    def test_token_ceiling_warns_but_does_not_block(self):
        lg = Ledger(self.root, {"rounds": {"limit": 1000, "action": "block"},
                                "tokens": {"limit": 100, "action": "warn", "warn_at": 0.8}})
        lg.record(tokens_in=50, tokens_out=35)
        warnings = lg.check()                       # 85% — warns
        self.assertTrue(any("tokens" in w for w in warnings))
        lg.record(tokens_in=1000, tokens_out=1000)  # far past the limit
        lg.check()                                  # must NOT raise

    def test_ledger_survives_a_torn_final_line(self):
        lg = Ledger(self.root)
        lg.record(rounds=1, station="a")
        with lg.path.open("a") as fh:
            fh.write('{"rounds": 1, "stat')       # killed mid-write
        self.assertEqual(lg.totals()["rounds"], 1)


# -------------------------------------------------------------- seal -------

class TestSeal(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.root = Path(self.td) / "repo"
        _repo(self.root)
        (self.root / "src").mkdir()
        (self.root / "src/app.py").write_text("print('x')\n")
        (self.root / "factory/tests/visible/test_v.py").write_text("assert True\n")
        (self.root / "factory/tests/heldout/test_h.py").write_text("# SECRET check\n")
        for a in (["init", "-q"], ["config", "user.email", "t@t"],
                  ["config", "user.name", "t"], ["add", "-A"], ["commit", "-qm", "i"]):
            subprocess.run(["git", "-C", str(self.root), *a], capture_output=True)

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_worker_sandbox_has_no_heldout_files_on_disk(self):
        wt = Path(self.td) / "sandbox"
        create_sealed_worktree(self.root, wt)
        self.assertFalse((wt / "factory/tests/heldout").exists())
        self.assertEqual(
            [p for p in wt.rglob("*") if "heldout" in p.parts and p.is_file()], [])
        # and the content is not reachable by any other path
        hits = subprocess.run(["grep", "-rl", "SECRET", str(wt)],
                              capture_output=True, text=True).stdout.strip()
        self.assertEqual(hits, "")
        # what the worker legitimately needs is still there
        self.assertTrue((wt / "factory/tests/visible/test_v.py").exists())
        self.assertTrue((wt / "src/app.py").exists())
        remove_worktree(self.root, wt)

    def test_a_leaky_tree_is_refused(self):
        wt = Path(self.td) / "leaky"
        subprocess.run(["git", "-C", str(self.root), "worktree", "add", "-q",
                        "--detach", str(wt), "HEAD"], capture_output=True)
        with self.assertRaises(SealError):
            verify_seal(wt)
        remove_worktree(self.root, wt)


# --------------------------------------------------------- verdict gc ------

class TestVerdictStaleness(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.root = _repo(Path(self.td))
        _install(self.root, "spec", "_spec.json")
        _install(self.root, "decompose", "_decompose.json")
        _install(self.root, "plan", "plan.pass1.json")
        self.store = Store(self.root)

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_advancing_the_head_discards_the_old_verdict(self):
        sha = self.store.stamp("plan")
        self.store.record(Verdict(gate="plan_review", sha=sha, verdict="APPROVE", passed=True))
        self.assertTrue(self.store.has_pass("plan_review", sha))

        p = self.store.path_for("plan")
        doc = json.loads(p.read_text())
        doc["slices"][0]["claim"] += " (amended)"
        p.write_text(json.dumps(doc))

        new_sha = self.store.stamp("plan")
        self.assertNotEqual(sha, new_sha)
        self.assertFalse(self.store.has_pass("plan_review", new_sha),
                         "an approval must not carry across an edit")
        removed = self.store.gc(self.store.live_shas())
        self.assertTrue(removed, "the stale verdict should have been collected")

    def test_content_sha_matches_git_hash_object(self):
        subprocess.run(["git", "-C", str(self.root), "init", "-q"], capture_output=True)
        p = self.store.path_for("spec")
        got = content_sha(p)
        want = subprocess.run(["git", "-C", str(self.root), "hash-object", str(p)],
                              capture_output=True, text=True).stdout.strip()
        self.assertEqual(got, want)


# ------------------------------------------------------------ workers ------

class _StubAdapter(Adapter):
    """Returns canned text without touching a real CLI."""
    def __init__(self, text: str):
        self.text = text
        self.role = type("R", (), {"name": "stub", "model": "stub",
                                   "cmd": ("true",), "input": "stdin"})()
        self.timeout = 5

    def invoke(self, prompt):                      # noqa: D102
        from foreman.workers import Result
        self._last_prompt = prompt
        return Result("stub", self.text, parse_status_block(self.text), {}, 0.0, 0)


class TestWorkers(unittest.TestCase):
    GOOD = ("---FACTORY_STATUS---\nSTATION: probe\nTASK_ID: T00\n"
            "STATUS: DONE\nSUMMARY: ok\n---END---")

    def test_parses_the_last_block_not_an_echoed_template(self):
        text = ("---FACTORY_STATUS---\nSTATION: template\nTASK_ID: -\n"
                "STATUS: BLOCKED\nSUMMARY: echo\n---END---\nchatter\n" + self.GOOD)
        sb = parse_status_block(text)
        self.assertEqual(sb.station, "probe")
        self.assertEqual(sb.status, "DONE")

    def test_malformed_blocks_are_rejected(self):
        self.assertIsNone(parse_status_block("no block here"))
        self.assertIsNone(parse_status_block("---FACTORY_STATUS---\nSTATUS: DONE\n"))
        bad = parse_status_block("---FACTORY_STATUS---\nSTATION: x\nSTATUS: MAYBE\n"
                                 "SUMMARY: y\n---END---")
        self.assertFalse(bad.ok, "MAYBE is not a valid status")

    def test_contract_test_fails_loudly_on_a_malformed_block(self):
        w = Workers()
        w._adapters["executor"] = _StubAdapter("I do not speak status blocks.")
        with self.assertRaises(ContractTestFailed):
            w.contract_test("executor")
        w._adapters["executor"] = _StubAdapter(
            "---FACTORY_STATUS---\nSTATION: p\nSTATUS: WAT\nSUMMARY: s\n---END---")
        with self.assertRaises(ContractTestFailed):
            w.contract_test("executor")

    def test_contract_test_accepts_a_well_formed_block(self):
        w = Workers()
        w._adapters["executor"] = _StubAdapter(self.GOOD)
        self.assertTrue(w.contract_test("executor").status_block.ok)

    def test_judges_never_receive_implementation_notes(self):
        """Channel separation is enforced by assembly, not by convention."""
        w = Workers()
        wo = WorkOrder(prefix="P", suffix="S", notes="I struggled with the race here")
        for judge in ("judge", "plan_judge"):
            self.assertNotIn("struggled", w.assemble(judge, wo),
                             f"{judge} was handed Implementation Notes")
        self.assertIn("struggled", w.assemble("executor", wo))

    def test_arg_mode_prompt_never_starts_with_a_dash(self):
        """Every skill file opens with '---'; an arg-mode CLI would eat it."""
        r = Router().role("executor")
        self.assertEqual(r.input, "arg")
        a = Adapter(r)
        argv, stdin_text = a.build_argv("---\nname: skill\n---\nbody")
        self.assertIsNone(stdin_text)
        self.assertFalse(argv[-1].startswith("-"))
        self.assertIn("name: skill", argv[-1])


# ----------------------------------------------------------- breakers ------

class TestBreakers(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.root = _repo(Path(self.td))

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_three_parks_stop_the_night(self):
        b = Breakers(self.root)
        self.assertFalse(b.record_park("T1", "x"))
        self.assertFalse(b.record_park("T2", "x"))
        self.assertTrue(b.record_park("T3", "x"))
        self.assertTrue(b.is_open)

    def test_three_empty_diffs_park_the_task(self):
        b = Breakers(self.root)
        self.assertFalse(b.record_empty_diff("T1"))
        self.assertFalse(b.record_empty_diff("T1"))
        self.assertTrue(b.record_empty_diff("T1"))

    def test_progress_resets_the_no_progress_counter(self):
        b = Breakers(self.root)
        b.record_empty_diff("T1"); b.record_empty_diff("T1")
        b.record_progress("T1")
        self.assertFalse(b.record_empty_diff("T1"))

    def test_same_error_five_times_parks(self):
        b = Breakers(self.root)
        for i in range(4):
            self.assertFalse(b.record_error("KeyError: 'x'"), i)
        self.assertTrue(b.record_error("KeyError: 'x'"))

    def test_cooldown_then_a_single_half_open_retry(self):
        now = [1000.0]
        b = Breakers(self.root, clock=lambda: now[0])
        b.trip("too many parks")
        self.assertTrue(b.is_open)
        now[0] += Breakers.COOLDOWN_S + 1
        self.assertTrue(b.may_retry(), "cooldown elapsed: one retry")
        self.assertFalse(b.may_retry(), "half-open allows exactly one")

    def test_breaker_state_survives_a_restart(self):
        Breakers(self.root).record_park("T1", "x")
        self.assertEqual(Breakers(self.root).state.parks, 1)

    def test_exit_needs_both_conditions(self):
        self.assertTrue(Breakers.may_exit(True, True))
        self.assertFalse(Breakers.may_exit(True, False))
        self.assertFalse(Breakers.may_exit(False, True))


# -------------------------------------------------------------- steps ------

KILL_SCRIPT = r'''
import sys, os, time
sys.path.insert(0, {root!r})
from foreman import steps as S
S.configure({repo!r})
marks = {marks!r}

@S.durable_step("stepA")
def a(x):
    open(marks, "a").write("A\n"); return x + 1

@S.durable_step("stepB")
def b(x):
    open(marks, "a").write("B\n"); return x * 2

@S.durable_step("stepC")
def c(x):
    open(marks, "a").write("C\n")
    if os.environ.get("CRASH") == "1":
        os.kill(os.getpid(), 9)     # kill -9 in the middle of the pipeline
    return x - 3

v = c(b(a(1)))
open(marks, "a").write(f"DONE {{v}}\n")
'''


class TestDurableSteps(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.repo = _repo(Path(self.td))
        self.marks = str(Path(self.td) / "marks.txt")
        self.script = Path(self.td) / "run.py"
        self.script.write_text(KILL_SCRIPT.format(
            root=str(ROOT), repo=str(self.repo), marks=self.marks))

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def _marks(self):
        return Path(self.marks).read_text().split() if Path(self.marks).exists() else []

    def test_kill_9_resumes_at_the_last_completed_step(self):
        env = dict(os.environ, CRASH="1")
        p = subprocess.run([sys.executable, str(self.script)], env=env, capture_output=True)
        self.assertEqual(p.returncode, -signal.SIGKILL)
        self.assertEqual(self._marks(), ["A", "B", "C"])

        # resume: A and B are memoized, only C re-runs
        Path(self.marks).write_text("")
        env = dict(os.environ, CRASH="0")
        p = subprocess.run([sys.executable, str(self.script)], env=env, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr.decode()[:400])
        marks = self._marks()
        self.assertNotIn("A", marks, "step A should have been memoized, not re-run")
        self.assertNotIn("B", marks, "step B should have been memoized, not re-run")
        self.assertIn("C", marks, "step C did not complete before the kill, so it must re-run")
        self.assertIn("DONE", marks)

    def test_a_completed_step_is_not_repeated(self):
        S.configure(self.repo)
        calls = []

        @S.durable_step("side_effect")
        def commit(msg):
            calls.append(msg)
            return {"sha": "abc123"}

        self.assertEqual(commit("one"), commit("one"))
        self.assertEqual(len(calls), 1, "a durable step must not repeat its side effect")
        commit("two")
        self.assertEqual(len(calls), 2, "different input must re-run")

    def test_changed_inputs_invalidate_the_memo(self):
        S.configure(self.repo)
        self.assertNotEqual(S.input_sha({"a": 1}), S.input_sha({"a": 2}))
        self.assertEqual(S.input_sha({"a": 1, "b": 2}), S.input_sha({"b": 2, "a": 1}))


# ---------------------------------------------------------------- e2e -----

class TestEndToEnd(unittest.TestCase):
    """Drive a toy project through the whole machine with mocked workers."""

    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.root = _repo(Path(self.td))
        _install(self.root, "spec", "_spec.json")
        _install(self.root, "decompose", "_decompose.json")
        _install(self.root, "plan", "plan.pass1.json")
        for adr in ("ADR-1", "ADR-2", "ADR-3"):
            (self.root / f"factory/adr/{adr}.md").write_text(f"# {adr}\ncontext/decision\n")
        runner = self.root / "factory/tests/run-visible.sh"
        runner.write_text("#!/usr/bin/env bash\nexit 0\n")
        runner.chmod(0o755)
        self.store = Store(self.root)
        self.fsm = FSM(self.root, self.store)
        self.ledger = Ledger(self.root, Router().ceilings())

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_full_pipeline_reaches_backlog(self):
        self.fsm._write_state("SPEC", "e2e")
        path = [("spec", "spec"), ("decompose", "decompose"),
                ("design_record", "decompose"), ("exam", "spec"),
                ("plan", "plan"), ("plan_review", "plan")]
        for gate, kind in path:
            sha = content_sha(self.store.path_for(kind))
            if gate == "plan_review":
                # the judged gate: mocked verdict, still cross-family checked
                Router().check_independence("plan_judge", "planner")
                self.store.record(Verdict(gate=gate, sha=sha, verdict="APPROVE",
                                          passed=True, judge_family="openai",
                                          author_family="anthropic"))
                res = G.GateResult(gate, True)
            else:
                res = G.ALL_GATES[gate](self.root)
                self.store.record(Verdict(gate=gate, sha=sha,
                                          verdict="PASS" if res.passed else "FAIL",
                                          passed=res.passed))
            self.assertTrue(res.passed, f"{gate}: {res.findings}")
            self.ledger.record(station=self.fsm.station(), role="foreman", rounds=1)
            try:
                self.fsm.fire(gate, sha)
            except GateNotPassed:
                pass   # a station with several gates stays put until all pass
        self.assertEqual(self.fsm.station(), "BACKLOG")
        self.assertGreater(self.ledger.totals()["rounds"], 0)

    def test_a_failing_gate_stops_the_line(self):
        _install(self.root, "spec", "spec.fail_no_nongoals.json")
        self.fsm._write_state("SPEC", "e2e")
        res = G.spec_gate(self.root)
        self.assertFalse(res.passed)
        sha = content_sha(self.store.path_for("spec"))
        self.store.record(Verdict(gate="spec", sha=sha, verdict="FAIL", passed=False))
        with self.assertRaises(GateNotPassed):
            self.fsm.fire("spec", sha)
        self.assertEqual(self.fsm.station(), "SPEC", "a failed gate must not advance")


if __name__ == "__main__":
    unittest.main(verbosity=2)
