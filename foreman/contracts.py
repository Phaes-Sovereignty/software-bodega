"""contracts.py — the typed artifact store, the verdict registry, and the seal.

Three jobs:

1. **Validate and SHA-stamp** spec / decompose / plan. Content SHA, not mtime —
   a rewrite with identical bytes is not a change.
2. **Verdict registry keyed by SHA.** A verdict is a statement about one exact
   artifact. When the head moves, every verdict bound to the old SHA is garbage
   and gets collected, rather than quietly carrying forward as an approval.
3. **Held-out sealing.** Worker sandboxes are git worktrees created with sparse
   checkout that EXCLUDES the held-out directory. Physical absence, not a
   promise in a prompt — the builder cannot read what is not on disk.
"""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "lib"))
import schemas  # noqa: E402  (shared with Phase B; one definition of each schema)

KINDS = {
    "spec": "factory/.planning/spec.json",
    "decompose": "factory/.planning/decompose.json",
    "plan": "factory/.planning/plan.json",
}


class ContractError(Exception):
    pass


def content_sha(path: Path) -> str:
    """Git-compatible blob SHA, so it matches `git hash-object`."""
    data = path.read_bytes()
    h = hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


@dataclass
class Verdict:
    gate: str
    sha: str
    verdict: str
    passed: bool
    judge_family: str = ""
    author_family: str = ""
    ts: str = ""
    round: int = 0
    detail: str = ""


class Store:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.gate_dir = self.root / "factory/.planning/gate-results"
        self.gate_dir.mkdir(parents=True, exist_ok=True)

    # --- typed artifacts --------------------------------------------------
    def path_for(self, kind: str) -> Path:
        if kind not in KINDS:
            raise ContractError(f"unknown artifact kind {kind!r}")
        return self.root / KINDS[kind]

    def validate(self, kind: str) -> list[str]:
        return schemas.validate_file(kind, str(self.path_for(kind)))

    def stamp(self, kind: str) -> str:
        """Validate, then return the content SHA. Refuses to stamp invalid data."""
        errs = self.validate(kind)
        if errs:
            raise ContractError(f"{kind} failed validation: {errs}")
        return content_sha(self.path_for(kind))

    # --- verdict registry -------------------------------------------------
    def verdict_path(self, gate: str, sha: str) -> Path:
        return self.gate_dir / f"{gate}-{sha}.json"

    def record(self, v: Verdict) -> Path:
        if not v.ts:
            v.ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        p = self.verdict_path(v.gate, v.sha)
        p.write_text(json.dumps(asdict(v), indent=2) + "\n")
        return p

    def verdict(self, gate: str, sha: str) -> Verdict | None:
        p = self.verdict_path(gate, sha)
        if not p.exists():
            return None
        d = json.loads(p.read_text())
        return Verdict(
            gate=d.get("gate", gate),
            sha=d.get("sha", sha),
            verdict=d.get("verdict", ""),
            # Phase B's shell writes "pass"; Phase C writes "passed". Read both,
            # so a night started under B can be inspected by C.
            passed=bool(d.get("passed", d.get("pass", False))),
            judge_family=d.get("judge_family", ""),
            author_family=d.get("author_family", ""),
            ts=d.get("ts", ""),
            round=int(d.get("round", 0) or 0),
            detail=d.get("detail", ""),
        )

    def has_pass(self, gate: str, sha: str) -> bool:
        v = self.verdict(gate, sha)
        return bool(v and v.passed)

    def gc(self, live_shas: set[str]) -> list[Path]:
        """Discard every verdict not bound to a currently-live artifact SHA.

        This is what makes "the head moved, so the approval is void" mechanical
        rather than a thing everyone remembers to do.
        """
        removed = []
        for p in sorted(self.gate_dir.glob("*.json")):
            sha = p.stem.rsplit("-", 1)[-1]
            if sha not in live_shas:
                p.unlink()
                removed.append(p)
        return removed

    def live_shas(self) -> set[str]:
        out = set()
        for kind in KINDS:
            p = self.path_for(kind)
            if p.exists():
                out.add(content_sha(p))
        return out


# --- held-out sealing ------------------------------------------------------

class SealError(Exception):
    pass


def _git(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(root), *args],
                          capture_output=True, text=True, check=check)


def create_sealed_worktree(root: Path, dest: Path, ref: str = "HEAD",
                           heldout: str = "factory/tests/heldout",
                           branch: str | None = None) -> Path:
    """A worker sandbox with the held-out suite physically absent.

    Sparse checkout excludes the directory, then it is removed for good measure
    (a sparse pattern can be widened by anything that runs `git sparse-checkout
    disable`; a missing directory cannot be un-deleted without the objects).
    Verified before returning — this function never hands back a leaky tree.
    """
    dest = Path(dest)
    if dest.exists():
        raise SealError(f"worktree destination already exists: {dest}")
    args = ["worktree", "add", "--no-checkout", "-q"]
    if branch:
        args += ["-b", branch]
    else:
        args += ["--detach"]
    args += [str(dest), ref]
    _git(root, *args)

    sub = lambda *a: subprocess.run(["git", "-C", str(dest), *a],  # noqa: E731
                                    capture_output=True, text=True)
    sub("sparse-checkout", "init", "--no-cone")
    sub("sparse-checkout", "set", "/*", f"!/{heldout}/", f"!/{heldout}/*")
    sub("checkout")
    shutil.rmtree(dest / heldout, ignore_errors=True)

    verify_seal(dest, heldout)
    return dest


def verify_seal(tree: Path, heldout: str = "factory/tests/heldout") -> None:
    """Raise if any held-out file is reachable inside the sandbox."""
    d = Path(tree) / heldout
    if d.exists():
        raise SealError(f"seal broken: {d} exists in the worker tree")
    leaked = [p for p in Path(tree).rglob("*")
              if heldout.split("/")[-1] in p.parts and p.is_file()
              and ".git" not in p.parts]
    if leaked:
        raise SealError(f"seal broken: {len(leaked)} held-out file(s) reachable: {leaked[:3]}")


def remove_worktree(root: Path, dest: Path) -> None:
    _git(root, "worktree", "remove", "--force", str(dest), check=False)
    _git(root, "worktree", "prune", check=False)
