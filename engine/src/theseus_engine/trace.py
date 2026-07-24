"""Trace recording: JSONL streams for the viewer and golden fixtures.

A trace is one header line followed by one line per simulation tick.
This exact schema (v1) is the contract between the Python engine, the
HTML viewer (tools/viewer/) and, later, the on-device diagnostic
recorder: an iPhone session recorded to the same schema can be replayed
through the desktop tooling. Floats are rounded before serialization so
traces are byte-stable and hashable (golden tests).
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

SCHEMA_VERSION = 1


def _rounded(obj, ndigits: int = 4):
    if isinstance(obj, float):
        r = round(obj, ndigits)
        return 0.0 if r == 0 else r  # avoid -0.0 leaking into hashes
    if isinstance(obj, dict):
        return {k: _rounded(v, ndigits) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_rounded(v, ndigits) for v in obj]
    return obj


def _canonical(obj) -> str:
    return json.dumps(_rounded(obj), sort_keys=True, separators=(",", ":"),
                      allow_nan=False)


# Fields that vary run-to-run without the BEHAVIOR changing. They are
# saved in trace files (the viewer shows them) but excluded from the
# golden hash, which certifies behavior only.
VOLATILE_FIELDS = frozenset({"replan_ms"})


class TraceWriter:
    """Collects trace lines in memory; optionally saves to a file.
    In-memory collection is what golden tests hash."""

    def __init__(self, header: dict):
        header = {"type": "header", "v": SCHEMA_VERSION, **header}
        self.lines: list[str] = [_canonical(header)]
        self._hash_lines: list[str] = [self.lines[0]]

    def frame(self, **fields) -> None:
        self.lines.append(_canonical({"type": "frame", **fields}))
        stable = {k: v for k, v in fields.items() if k not in VOLATILE_FIELDS}
        self._hash_lines.append(_canonical({"type": "frame", **stable}))

    def sha256(self) -> str:
        return hashlib.sha256("\n".join(self._hash_lines).encode("utf-8")).hexdigest()

    def save(self, path: str | Path, include_volatile: bool = True) -> Path:
        """Write the trace. Golden fixtures pass include_volatile=False so
        the committed files are byte-stable across regenerations (volatile
        fields like replan_ms differ run-to-run without any behavior
        change and would dirty git on every regen)."""
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        lines = self.lines if include_volatile else self._hash_lines
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p
