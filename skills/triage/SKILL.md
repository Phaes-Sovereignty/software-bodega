---
name: triage
description: Classify an incoming issue as OBVIOUS (label ready, start immediately) or AMBIGUOUS (ask 1-3 questions first). When in doubt, AMBIGUOUS.
---

# Station: TRIAGE (Small Loop)

Role: **triage**. Input: one issue title + body. Runs in ~30 seconds. Output: a
classification and, if needed, the questions.

## The two buckets

**OBVIOUS** — the fix is clear and the checks are writable *right now*, without
asking the human anything:
- a bug **with a reproduction** (steps, or a failing test, or a stack trace)
- a small feature whose behavior is fully described
- a dependency bump
- a failing test in CI

**AMBIGUOUS** — anything where scope or intended behavior is unclear:
- "improve X", "make it faster", "clean up Y"
- a feature where you would have to invent the acceptance criteria
- anything touching a documented non-goal (NG-N) — that needs a human decision
- a bug with no repro
- anything that would change a signed contract

## The tie-breaker

**When in doubt → AMBIGUOUS.** The costs are asymmetric. A wrong AMBIGUOUS costs
the human 30 seconds answering a question. A wrong OBVIOUS costs a night of
autonomous work building the wrong thing, plus review time to discover it. Do
not optimize for looking decisive.

The test for OBVIOUS is not "do I understand the words" — it is: **can I write
the acceptance check right now, and would a second engineer write the same
one?** If you cannot state the check in one sentence, it is AMBIGUOUS.

## If OBVIOUS

Emit the acceptance checks you would write. Label the issue `ready`. Work starts
immediately — no human wait.

```
CLASSIFICATION: OBVIOUS
LABEL: ready
CHECKS:
- <check 1, machine-verifiable>
- <check 2>
BOUNDARY: <files this should touch>
```

## If AMBIGUOUS

Ask **1–3 questions maximum**, each with a recommended answer. Never more than
three — this is a 30-second station, not a second interview. Pick the questions
whose answers change the implementation most.

```
CLASSIFICATION: AMBIGUOUS
LABEL: needs-info
QUESTIONS:
1. <question> (recommend: <answer>)
2. <question> (recommend: <answer>)
```

The issue becomes `ready` once answered.

End with the standard block (`STATION: triage`, `TASK_ID: <issue number>`).
