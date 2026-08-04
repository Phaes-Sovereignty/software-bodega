"""steps.py — durable, memoized steps so `kill -9` costs one step, not a night.

A step is identified by (step_id, SHA of its inputs). Its result is written to
factory/.steps/<step_id>-<input_sha>.json. Re-running a completed step returns
the cached result instead of re-invoking a model or re-running a suite.

Two properties matter:

- **Resume**: after a crash, replaying the pipeline skips everything already
  done and continues at the first incomplete step.
- **Idempotency**: a step with a side effect (a commit, a webhook) records an
  idempotency key so the replay does not do it twice.

Inputs must be hashable to JSON. If a step's inputs change, its SHA changes and
it legitimately re-runs — that is the point, not a cache miss to work around.
"""
from __future__ import annotations

import functools
import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any, Callable

_STATE: dict[str, Any] = {"root": None, "enabled": True}


def configure(root: Path, enabled: bool = True) -> None:
    _STATE["root"] = Path(root)
    _STATE["enabled"] = enabled
    steps_dir(Path(root)).mkdir(parents=True, exist_ok=True)


def steps_dir(root: Path | None = None) -> Path:
    r = Path(root or _STATE["root"] or ".")
    return r / "factory/.steps"


def input_sha(payload: Any) -> str:
    """Stable hash of a step's inputs. Sorted keys so dict order never matters."""
    blob = json.dumps(payload, sort_keys=True, default=str, separators=(",", ":"))
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def _record_path(step_id: str, sha: str, root: Path | None = None) -> Path:
    return steps_dir(root) / f"{step_id}-{sha}.json"


def completed(step_id: str, sha: str, root: Path | None = None) -> bool:
    return _record_path(step_id, sha, root).exists()


def load(step_id: str, sha: str, root: Path | None = None) -> Any:
    p = _record_path(step_id, sha, root)
    return json.loads(p.read_text())["result"]


def save(step_id: str, sha: str, result: Any, root: Path | None = None,
         idempotency_key: str | None = None) -> Path:
    p = _record_path(step_id, sha, root)
    p.parent.mkdir(parents=True, exist_ok=True)
    body = {
        "step_id": step_id,
        "input_sha": sha,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "idempotency_key": idempotency_key,
        "result": result,
    }
    # Write-then-rename: a crash mid-write must not leave a half-parsed record
    # that reads as "this step completed".
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(body, indent=2, default=str) + "\n")
    os.replace(tmp, p)
    return p


def durable_step(step_id: str, key: Callable[..., Any] | None = None):
    """Memoize a function by (step_id, SHA of its arguments).

    `key` extracts the hashable input from the call arguments when the raw
    arguments are not JSON-serialisable (a Path, an open handle, a Router).
    """
    def deco(fn: Callable[..., Any]) -> Callable[..., Any]:
        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            if not _STATE["enabled"]:
                return fn(*args, **kwargs)
            payload = key(*args, **kwargs) if key else {"a": args, "k": kwargs}
            sha = input_sha(payload)
            if completed(step_id, sha):
                return load(step_id, sha)
            result = fn(*args, **kwargs)
            save(step_id, sha, result, idempotency_key=f"{step_id}:{sha}")
            return result
        wrapper.step_id = step_id  # type: ignore[attr-defined]
        return wrapper
    return deco


def reset(step_id: str | None = None, root: Path | None = None) -> int:
    """Forget cached steps. Without an id, forgets everything."""
    d = steps_dir(root)
    if not d.exists():
        return 0
    n = 0
    for p in d.glob("*.json"):
        if step_id is None or p.name.startswith(f"{step_id}-"):
            p.unlink()
            n += 1
    return n


def summary(root: Path | None = None) -> list[dict[str, Any]]:
    d = steps_dir(root)
    if not d.exists():
        return []
    out = []
    for p in sorted(d.glob("*.json")):
        try:
            b = json.loads(p.read_text())
        except json.JSONDecodeError:
            continue
        out.append({"step_id": b.get("step_id"), "input_sha": b.get("input_sha"),
                    "ts": b.get("ts")})
    return out
