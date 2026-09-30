#!/usr/bin/env bash
# test-swift-cycle.sh — run a REAL Swift package through a sealed exam-and-verify
# cycle. No model calls, no greps about Swift: this compiles and tests.
#
# Why this file exists: the Swift half of Bodega "passed" selftest for as long as
# it existed because every check was `grep -q "toolchain.env"` or
# `grep -q "manifest-cache none"`. The strings were present; the mechanism was
# not wired. That is the Sancho thesis applied to the tool itself — a verifier
# that checks the declaration instead of the behavior certifies the declaration
# of a broken system.
#
# What is proven here, in order:
#   1. detection + resolve produce a Swift profile whose HELDOUT_DIR is
#      Tests/HeldoutTests (not the Python default)
#   2. the exam board's conditional-target Package.swift BUILDS with the held-out
#      directory absent — the requirement the skill states and nothing checked
#   3. the seal removes Tests/HeldoutTests from a worker worktree, physically
#   4. the visible suite RUNS AND PASSES inside that sealed tree, via the
#      declared VISIBLE_CMD
#   5. the held-out suite RUNS via the declared HELDOUT_CMD and a red held-out
#      test is reported red (the mechanism can fail, so it can also mean it)
#   6. the OLD hard-coded seal would have leaked: sealing factory/tests/heldout
#      leaves Tests/HeldoutTests readable. This assertion is the regression test
#      for item 1 of the bug list.
#
# Usage: bash scripts/tests/test-swift-cycle.sh
# Skips (exit 0 with a notice) when no Swift toolchain is available.

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

SWIFT="$(command -v swift || true)"
[ -n "$SWIFT" ] || SWIFT="$(xcrun --find swift 2>/dev/null || true)"
if [ -z "$SWIFT" ]; then
  printf '  \033[33m–\033[0m no swift toolchain — skipping the compiled seal cycle\n'
  printf '\n0 passed, 0 failed (skipped)\n'
  exit 0
fi

cleanup() {
  while IFS= read -r w; do
    [ -n "$w" ] && git -C "$PROJ" worktree remove --force "$w" >/dev/null 2>&1
  done < <(git -C "${PROJ:-/nonexistent}" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

TMP="$(mktemp -d)"
export CLANG_MODULE_CACHE_PATH="$TMP/modcache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

# CAPABILITY PROBE. A toolchain that exists but cannot compile is not the
# product's failure, and reporting it as one buries the real signal — SwiftPM
# shells out through sandbox-exec, which nested sandboxes (CI-in-container, an
# agent harness) refuse, and every assertion below then fails identically to a
# broken seal. Probe with a throwaway package FIRST and skip LOUDLY if the
# compiler cannot run. Skipping is visible: selftest prints the reason, and a
# seal this file certifies is a seal it actually watched compile.
PROBE="$TMP/probe"; mkdir -p "$PROBE/Sources/P" "$PROBE/Tests/PTests"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "P", targets: [.target(name: "P"), .testTarget(name: "PTests", dependencies: ["P"])])\n' > "$PROBE/Package.swift"
printf 'public func p() -> Int { 1 }\n' > "$PROBE/Sources/P/P.swift"
printf 'import XCTest\n@testable import P\nfinal class PTests: XCTestCase { func testP() { XCTAssertEqual(p(), 1) } }\n' > "$PROBE/Tests/PTests/PTests.swift"
if ! ( cd "$PROBE" && "$SWIFT" test >/dev/null 2>&1 ); then
  printf '  \033[33m–\033[0m swift test cannot run HERE (probe failed) — skipping the compiled cycle\n'
  printf '  \033[33m–\033[0m this is an environment limit, NOT a pass: run on a host where SwiftPM can compile\n'
  printf '\n0 passed, 0 failed (skipped: swiftpm unavailable)\n'
  exit 0
fi

# --- build the fixture package ---------------------------------------------
PROJ="$TMP/pkg"
mkdir -p "$PROJ/scripts/lib" "$PROJ/skills/night-task" "$PROJ/factory" \
         "$PROJ/Sources/App" "$PROJ/Tests/VisibleTests" "$PROJ/Tests/HeldoutTests"
cp "$SRC"/scripts/*.sh "$PROJ/scripts/"
cp "$SRC"/scripts/lib/*.sh "$PROJ/scripts/lib/"
cp "$SRC"/models.env "$PROJ/"
printf 'worker skill\n' > "$PROJ/skills/night-task/SKILL.md"
: > "$PROJ/factory/progress.md"; : > "$PROJ/factory/log.md"
printf 'STAGE: IDLE\nPOINTER: -\n' > "$PROJ/factory/STATE.md"

# AC-1: the app normalises a name. The visible test checks the happy path; the
# held-out test checks a boundary the visible suite does not mention — exactly
# the partition the exam board is told to author.
cat > "$PROJ/Sources/App/Name.swift" <<'SW'
import Foundation

public struct Name {
    public let value: String
    public init(_ raw: String) {
        // Intentionally wrong at first: the held-out exam catches it, the
        // visible one does not. That asymmetry IS the mechanism under test.
        value = raw
    }
}
SW

cat > "$PROJ/Tests/VisibleTests/VisibleTests.swift" <<'SW'
import XCTest
@testable import App

final class VisibleTests: XCTestCase {
    func testNonEmptyNameIsKept() {
        XCTAssertEqual(Name("ada").value, "ada")
    }
    func testLongerNameIsKept() {
        XCTAssertEqual(Name("grace hopper").value, "grace hopper")
    }
    func testSingleCharIsKept() {
        XCTAssertEqual(Name("x").value, "x")
    }
}
SW

cat > "$PROJ/Tests/HeldoutTests/HeldoutTests.swift" <<'SW'
import XCTest
@testable import App

final class HeldoutTests: XCTestCase {
    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(Name("  ada  ").value, "ada")
    }
    func testBlankCollapsesToEmpty() {
        XCTAssertEqual(Name("   ").value, "")
    }
}
SW

# The exam board's conditional manifest, verbatim in shape.
cat > "$PROJ/Package.swift" <<'SW'
// swift-tools-version:5.9
import PackageDescription
import Foundation

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
SW

printf '.build/\nPackage.resolved\n' > "$PROJ/.gitignore"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm "exam board: suites + manifest" ) >/dev/null 2>&1

echo "swift sealed exam-and-verify cycle"

# --- 1. detection produces a Swift profile ---------------------------------
( cd "$PROJ" && env -u FACTORY_ROOT bash scripts/toolchain.sh resolve >/dev/null 2>&1 )
HD="$( cd "$PROJ" && env -u FACTORY_ROOT bash scripts/toolchain.sh get HELDOUT_DIR )"
VD="$( cd "$PROJ" && env -u FACTORY_ROOT bash scripts/toolchain.sh get VISIBLE_CMD )"
[ "$HD" = "Tests/HeldoutTests" ] \
  && ok "resolve detected Swift and set HELDOUT_DIR=Tests/HeldoutTests" \
  || bad "HELDOUT_DIR is '$HD' — a Swift project would be sealed at the wrong path"
case "$VD" in *"swift test"*) ok "VISIBLE_CMD is a swift command ($VD)" ;;
  *) bad "VISIBLE_CMD is '$VD'" ;;
esac
( cd "$PROJ" && env -u FACTORY_ROOT bash scripts/toolchain.sh check >/dev/null 2>&1 ) \
  && ok "toolchain check PASSES the generated Swift profile" \
  || bad "toolchain check rejected its own generated Swift profile"
( cd "$PROJ" && git add factory/toolchain.env && git commit -qm "toolchain: swift profile" ) >/dev/null 2>&1

# --- 2/3/4. seal a worktree the way runner.sh does, then BUILD AND TEST -----
# The seal is done exactly as scripts/runner.sh does it. Note the source path:
# a --no-checkout worktree is EMPTY, so lib/status.sh must come from the project,
# and the patterns go through the SPARSE_ARGS array — `$(sparse_patterns)`
# unquoted glob-expands `/*` into /Applications /Library /Users … and the
# checkout comes back with nothing in it while the log says the seal held.
WT="$TMP/wt"
(
  cd "$PROJ" && git worktree add -q --no-checkout --detach "$WT" HEAD 2>/dev/null
  # shellcheck disable=SC1090
  unset FACTORY_ROOT
  . "$PROJ/scripts/lib/status.sh"
  cd "$WT" || exit 1
  git sparse-checkout init --no-cone -q 2>/dev/null
  sparse_args
  git sparse-checkout set -q "${SPARSE_ARGS[@]}" 2>/dev/null
  git checkout -q 2>/dev/null
  seal_tree "$WT"
) >/dev/null 2>&1

# The worktree must actually contain the project — otherwise every assertion
# below passes because the tree is empty rather than because it is sealed.
[ -f "$WT/Package.swift" ] && [ -f "$WT/Sources/App/Name.swift" ] \
  && ok "sealed worktree contains the package and its source" \
  || bad "sealed worktree is missing the package (checkout produced an empty tree)"

if [ -d "$WT/Tests/HeldoutTests" ]; then
  bad "SEAL BROKEN: Tests/HeldoutTests exists in the worker worktree"
else
  ok "held-out target physically absent from the worker worktree"
fi
[ -f "$WT/Tests/VisibleTests/VisibleTests.swift" ] \
  && ok "visible suite IS present (worker can still drive TDD)" \
  || bad "visible suite missing — worker cannot verify anything"
[ -f "$WT/Package.swift" ] && ok "manifest present in the sealed tree" \
  || bad "manifest missing from sealed tree"

# The content must be unreachable, not merely the directory name.
if grep -rq "WhitespaceIsTrimmed" "$WT" 2>/dev/null; then
  bad "held-out ASSERTION text is readable inside the sealed tree"
else
  ok "held-out assertion text is unreachable by content search"
fi

# --- 4b. the visible suite must COMPILE AND PASS in the sealed tree ---------
# This is the requirement the exam-board skill states ("the visible suite must
# build and run in a checkout where the held-out directory does not exist") and
# that no grep could ever have checked.
VIS_RC=1
if [ -n "$SWIFT" ]; then
  ( cd "$WT" && bash -c 'unset FACTORY_ROOT; . scripts/lib/status.sh && run_visible_suite "$1"' _ "$TMP/vis.log" ) >/dev/null 2>&1
  VIS_RC=$?
fi
if [ "$VIS_RC" = "0" ]; then
  ok "visible suite BUILDS AND PASSES with the held-out target absent"
else
  bad "visible suite failed in the sealed tree (rc=$VIS_RC): $(tail -5 "$TMP/vis.log" 2>/dev/null | tr '\n' ' ')"
fi
# And the receipt must be parseable by the shared verifier — a Swift receipt the
# loop cannot read is how a build failure became "no regression".
# shellcheck disable=SC1091
. "$SRC/scripts/lib/verify.sh"
VF="$(LAST_TEST_RC=$VIS_RC fail_count "$TMP/vis.log")"
[ "$VF" = "0" ] && ok "verify.sh reads the swift receipt as 0 failures" \
  || bad "verify.sh counted $VF failures on a green swift run"

# --- 5. the held-out suite RUNS and a red exam is reported red --------------
( cd "$PROJ" && bash -c 'unset FACTORY_ROOT; . scripts/lib/status.sh && run_heldout_suite "$1"' _ "$TMP/held.log" ) >/dev/null 2>&1
HELD_RC=$?
if [ "$HELD_RC" = "0" ]; then
  bad "held-out suite PASSED against an unimplemented contract — it tests nothing"
else
  ok "held-out suite RUNS and FAILS the stub implementation (rc=$HELD_RC)"
fi
HF="$(LAST_TEST_RC=$HELD_RC fail_count "$TMP/held.log")"
[ "$HF" -ge 1 ] 2>/dev/null \
  && ok "verify.sh counts $HF failing held-out check(s) from the swift receipt" \
  || bad "verify.sh reported $HF failures for a red held-out run (rc=$HELD_RC) — the seal's whole purpose is defeated"

# Now make the contract true and show the same command goes green: the suite is
# sensitive to behaviour, not to luck.
cat > "$PROJ/Sources/App/Name.swift" <<'SW'
import Foundation

public struct Name {
    public let value: String
    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
SW
( cd "$PROJ" && bash -c 'unset FACTORY_ROOT; . scripts/lib/status.sh && run_heldout_suite "$1"' _ "$TMP/held2.log" ) >/dev/null 2>&1
H2=$?
if [ "$H2" = "0" ]; then
  ok "after implementing the contract, the held-out suite goes GREEN"
else
  bad "held-out suite still red after implementing the contract (rc=$H2): $(tail -5 "$TMP/held2.log" | tr '\n' ' ')"
fi
H2F="$(LAST_TEST_RC=$H2 fail_count "$TMP/held2.log")"
[ "$H2F" = "0" ] && ok "verify.sh reads the green swift receipt as 0 failures" \
  || bad "verify.sh counted $H2F on a green run"

# --- 6. the OLD hard-coded seal would have leaked ---------------------------
# Seal factory/tests/heldout (the pre-fix constant) in a second worktree and
# prove Tests/HeldoutTests is still readable there. If this ever stops being
# true, the declared-path seal is no longer doing anything the old one did not.
LEAKWT="$TMP/leakwt"
(
  cd "$PROJ" && git worktree add -q --no-checkout --detach "$LEAKWT" HEAD 2>/dev/null
  cd "$LEAKWT" || exit 1
  git sparse-checkout init --no-cone -q 2>/dev/null
  git sparse-checkout set '/*' '!/factory/tests/heldout/' '!/factory/tests/heldout/*' -q 2>/dev/null
  git checkout -q 2>/dev/null
  rm -rf factory/tests/heldout 2>/dev/null
) >/dev/null 2>&1
if grep -rq "WhitespaceIsTrimmed" "$LEAKWT" 2>/dev/null; then
  ok "regression proof: the OLD default-path seal leaves the Swift exam readable"
else
  bad "could not reproduce the original leak — this test would no longer catch it"
fi
# Same project, same declaration — no override. tree_is_sealed must refuse this
# tree because the directory the PROJECT declares is still sitting in it.
if ( unset FACTORY_ROOT; . "$PROJ/scripts/lib/status.sh" && tree_is_sealed "$LEAKWT" ) >/dev/null 2>&1; then
  bad "tree_is_sealed PASSED a tree that still contains Tests/HeldoutTests"
else
  ok "tree_is_sealed refuses the old-style seal (declared dir still present)"
fi
# ...and it must PASS the correctly sealed tree, or the check is just always-fail.
if ( unset FACTORY_ROOT; . "$PROJ/scripts/lib/status.sh" && tree_is_sealed "$WT" ) >/dev/null 2>&1; then
  ok "tree_is_sealed accepts the correctly sealed worktree"
else
  bad "tree_is_sealed rejected the tree that IS sealed — the check is broken"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
