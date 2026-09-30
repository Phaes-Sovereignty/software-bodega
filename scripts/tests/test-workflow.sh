#!/usr/bin/env bash
# test-workflow.sh — verify .github/workflows/factory.yml actually honours the
# project's declared toolchain, and that every run: block is valid shell.
#
# A workflow cannot be executed locally, so this is the one place a structural
# read of YAML is the right tool. It is NOT a grep: it parses the document and
# asserts on the job graph, the runner expressions, and where the held-out job
# unpacks its tarball. The pre-fix workflow hard-coded python3 +
# factory/tests/heldout + run-heldout.sh, so a Swift PR unpacked its exam into a
# directory the project does not use and then ran a script that does not exist.
#
# Skips LOUDLY when PyYAML is missing. A missing dependency is not a broken
# factory, and reporting it as one is how red output stops meaning anything.
#
# Usage: bash scripts/tests/test-workflow.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

cd "$SRC" || exit 1
WF=".github/workflows/factory.yml"
[ -f "$WF" ] || { bad "$WF is missing"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

PY="${PYTHON:-python3}"
if ! "$PY" -c 'import yaml' >/dev/null 2>&1; then
  printf '  \033[33m–\033[0m %s has no PyYAML — factory.yml is UNVERIFIED, not green\n' "$PY"
  printf '  \033[33m–\033[0m install pyyaml (or set PYTHON=... ) before trusting a push\n'
  printf '\n0 passed, 0 failed (skipped: pyyaml unavailable)\n'
  exit 0
fi

echo "CI workflow — structure and toolchain wiring"

# --- 1. job graph ----------------------------------------------------------
if "$PY" - <<'PY'
import yaml
j = yaml.safe_load(open('.github/workflows/factory.yml'))['jobs']
want = {'detect','build','visible','heldout','scope','review'}
assert set(j) == want, f"job set {sorted(j)} != {sorted(want)}"
assert j['review']['needs'] == ['detect','visible','heldout','scope'], \
    f"review needs {j['review']['needs']}"
PY
then ok "job graph: detect -> build -> {visible,heldout,scope} -> review"; else bad "job graph wrong"; fi

# --- 2. detect is the single source of the toolchain ----------------------
if "$PY" - <<'PY'
import yaml
j = yaml.safe_load(open('.github/workflows/factory.yml'))['jobs']
o = j['detect']['outputs']
for k in ('heldout_dir','visible_cmd','heldout_cmd','runner'):
    assert k in o, f"detect does not export {k}"
for name in ('build','visible','heldout','scope','review'):
    assert 'detect' in str(j[name].get('needs','')), f"{name} does not depend on detect"
    assert "needs.detect.outputs.runner" in str(j[name].get('runs-on','')), \
        f"{name} hard-codes its runner"
PY
then ok "every job runs on the runner detect chose (no python-only ubuntu assumption)"; else bad "a job ignores the detected runner"; fi

# --- 3. the held-out job unpacks into the DECLARED directory --------------
if "$PY" - <<'PY'
import yaml
j = yaml.safe_load(open('.github/workflows/factory.yml'))['jobs']
fetch = next(s for s in j['heldout']['steps'] if 'Fetch held-out suite from secrets' in s.get('name',''))
assert 'HELDOUT_DIR' in fetch.get('env',{}), "fetch does not pass the declared dir"
assert 'factory/tests/heldout' not in fetch['run'], "fetch still hard-codes the default path"
assert '$HELDOUT_DIR' in fetch['run'], "fetch does not use the declared dir"
run = next(s for s in j['heldout']['steps'] if s.get('name') == 'Held-out suite')
assert 'HELDOUT_CMD' in run.get('env',{}), "held-out job does not use the declared command"
assert 'run-heldout.sh' not in run['run'], "held-out job still calls the python runner script"
PY
then ok "held-out job unpacks and runs via HELDOUT_DIR / HELDOUT_CMD (not hard-coded)"; else bad "held-out job is still python-only"; fi

# --- 4. missing evidence still fails --------------------------------------
if "$PY" - <<'PY'
import yaml
j = yaml.safe_load(open('.github/workflows/factory.yml'))['jobs']
fetch = next(s for s in j['heldout']['steps'] if 'Fetch held-out suite from secrets' in s.get('name',''))
assert 'HELDOUT_TESTS' in fetch['run'] and 'exit 1' in fetch['run'], \
    "an empty secret no longer fails the job"
vis = next(s for s in j['visible']['steps'] if s.get('name') == 'Visible suite')
assert 'cannot prove green' in vis['run'], "a missing visible command no longer fails"
PY
then ok "empty secret / missing command FAILS the job (missing evidence is not green)"; else bad "a job can now pass with no evidence"; fi

# --- 5. scope job delegates to the tested script --------------------------
if "$PY" - <<'PY'
import yaml
j = yaml.safe_load(open('.github/workflows/factory.yml'))['jobs']
sc = next(s for s in j['scope']['steps'] if 'Scope + seal check' in s.get('name',''))
assert 'ci-scope.sh' in sc['run'], "scope job re-implements the check inline again"
PY
then ok "scope job calls scripts/ci-scope.sh — the same file the selftest exercises"; else bad "scope job has its own inline logic (untestable)"; fi

# --- 6. every run: block is valid shell -----------------------------------
if "$PY" - <<'PY'
import yaml, subprocess, tempfile, os, sys
d = yaml.safe_load(open('.github/workflows/factory.yml'))
bad = []
for jn, j in d['jobs'].items():
    for i, s in enumerate(j['steps']):
        if 'run' not in s: continue
        src = s['run'].replace('${{', '$OPEN').replace('}}', '')
        with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False) as f:
            f.write(src); p = f.name
        if subprocess.run(['bash','-n',p], capture_output=True).returncode:
            bad.append(f"{jn}.step[{i}]")
        os.unlink(p)
if bad:
    print("invalid: " + ", ".join(bad), file=sys.stderr)
sys.exit(1 if bad else 0)
PY
then ok "every CI run: block parses as bash"; else bad "a CI run: block is not valid shell"; fi

# --- 7. no hard-coded held-out path in the jobs that ACT on files ----------
# The literal may appear in exactly one place: detect's guard, which compares the
# RESOLVED value against the default to catch "Swift package, no declaration".
# Anywhere else it is a hard-coded path again, which is the bug being closed.
OFFENDERS="$("$PY" - <<'PY' 2>/dev/null
import yaml
j = yaml.safe_load(open('.github/workflows/factory.yml'))['jobs']
out = []
for name in ('visible','heldout','scope','review','build'):
    for s in j[name]['steps']:
        blob = str(s.get('run','')) + str(s.get('with',''))
        if 'factory/tests/heldout' in blob:
            out.append(f"{name}/{s.get('name','step')}")
print(",".join(out))
PY
)"
[ -z "$OFFENDERS" ] \
  && ok "no job acts on a hard-coded held-out path" \
  || bad "hard-coded held-out path in: $OFFENDERS"

# detect's guard must still exist — it is what catches an undeclared Swift
# project, which would otherwise seal an empty directory and read its own exam.
if "$PY" - <<'PY'
import yaml
j = yaml.safe_load(open('.github/workflows/factory.yml'))['jobs']
det = next(s for s in j['detect']['steps'] if 'Refuse' in s.get('name',''))
assert 'factory/tests/heldout' in det['run'] and 'Tests/HeldoutTests' in det['run']
assert 'exit 1' in det['run'], "the guard does not fail the build"
PY
then ok "detect refuses a Swift package that never declared HELDOUT_DIR"; else bad "detect's undeclared-Swift guard is missing or inert"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
