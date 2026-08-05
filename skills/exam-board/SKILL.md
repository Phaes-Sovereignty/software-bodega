---
name: exam-board
description: Fresh spec-blind session that authors CONTRACT.md plus visible and held-out test suites, partitioned at authoring time. The builder never sees the held-out half.
---

# Station: EXAM BOARD

Role: **planner**, in a **fresh session that has seen no implementation and no
plan**. This isolation is the entire point of the station. If you have been
reading the blueprint or writing code in this session, stop and start a new one.

Input: `factory/.planning/spec.json` only.
Output: `factory/CONTRACT.md`, `factory/tests/visible/*`, `factory/tests/heldout/*`.

## The partition — decided now, never later

You split tests into visible and held-out **at authoring time**, before any code
exists. This is what makes the held-out half meaningful: it cannot be
reverse-engineered from what the builder was allowed to see.

**`factory/tests/visible/`** — the builder sees these and drives TDD against
them. They cover the happy path and the obvious errors. Roughly 70% of checks.

**`factory/tests/heldout/`** — the builder **never** sees these. They test the
same criteria from an angle the visible tests do not: resource leaks across many
cycles, behavior when a dependency dies mid-operation, performance at 100× the
toy input, boundary values, idempotency on retry. Roughly 30%, minimum 2.

Design rule: for a held-out test to be worth having, an implementation that
games the visible suite must **fail** it. Before writing each held-out test ask
"could someone pass the visible tests and still fail this?" If no, the test is
redundant — write a better one.

Never write a held-out test that depends on an internal function name or a file
path. It must test observable behavior, or it will break on any honest refactor
and teach the factory to distrust its own exams.

## The partition must survive the build system

In a scripting language the seal is free: delete the directory and nothing
notices. In a **compiled** language the build manifest names its test targets,
so removing the held-out directory breaks the build for the builder — who then
cannot run *any* test, and every task parks. Whatever the toolchain, the rule
is: **the visible suite must build and run in a checkout where the held-out
directory does not exist.** Prove it before you leave the station.

### Swift — XCTest, two test targets

Write XCTest (`import XCTest`, `XCTestCase` subclasses, `XCTAssert*`), not
swift-testing. Bodega's parser counts both, but XCTest is what
`swift test --filter` slices cleanly per task.

Split into two test targets, mirroring the partition:

```
Tests/VisibleTests/    →  the builder sees these
Tests/HeldoutTests/    →  sealed; absent from the builder's checkout
```

`Package.swift` is Swift *code*, evaluated at build time — so declare the
held-out target only when its directory is actually present:

```swift
// swift-tools-version:5.9
import PackageDescription
import Foundation

// #filePath, not "Tests/HeldoutTests": the manifest is NOT evaluated with the
// package root as its working directory, so a relative path checks the wrong
// place, comes back true, and the sealed build fails with
//   "Source files for target HeldoutTests should be located under ..."
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let heldoutPresent = FileManager.default.fileExists(
    atPath: root.appendingPathComponent("Tests/HeldoutTests").path)

var targets: [Target] = [
    .target(name: "App"),
    .testTarget(name: "VisibleTests", dependencies: ["App"]),
]
if heldoutPresent {
    targets.append(.testTarget(name: "HeldoutTests", dependencies: ["App"]))
}

let package = Package(name: "App", targets: targets)
```

Two consequences you must respect:

- **Run the held-out suite with `--manifest-cache none`.** SwiftPM caches the
  evaluated manifest keyed on the manifest's *contents*, not on the filesystem
  it inspected. Without the flag a run can reuse a manifest evaluated while the
  seal was in the other state, and the held-out target silently vanishes —
  reporting `Executed 0 tests` as success.
- **Run it in a fresh checkout**, never by restoring the directory in place.
  `.build` caches the target list too. Bodega already does this: the seal is a
  sparse-checkout worktree, and CI unpacks `HELDOUT_TESTS` into a clean tree.

Before you finish, verify the seal by hand: move `Tests/HeldoutTests` aside, run
`swift build`, confirm it succeeds, and put it back. If the build breaks, the
manifest is wrong and no task will ever pass.

## CONTRACT.md — signed by the human, immutable thereafter

```markdown
# CONTRACT: <project>

## What this must do
- AC-1: <criterion> — checked by: <visible|heldout> / <test file>
- ...

## What this must not do
- NG-1: ...

## Definition of done
The visible suite exits 0 twice in a row, the held-out suite exits 0, and no
file outside a task's declared boundary changed.
```

Every AC-N in spec.json appears here with at least one check. Once the human
signs, this file is **never edited and never weakened** — not by you, not by the
night shift, not by the inspector. A contract that turned out wrong is a new
contract with a new signature, not a quiet edit.

## exam_gate

- [ ] ≥3 visible checks and ≥2 held-out checks
- [ ] every AC-N is covered by at least one check
- [ ] the visible suite **runs and exits 0 against an empty/skeleton repo only
      where it should** — tests must fail before the feature exists (a test that
      passes on empty code tests nothing)
- [ ] no held-out test references an internal symbol or path
- [ ] held-out files are listed in `.gitignore` for worker worktrees / excluded
      by sparse checkout (Phase C) — physical absence, not a promise
- [ ] **the visible suite builds and runs with the held-out directory removed** —
      checked by actually removing it, not by reading the manifest
- [ ] the visible tests can be sliced per task, so BLUEPRINT can write a
      `verify` command narrower than the whole suite

End with the standard block (`STATION: exam-board`).
