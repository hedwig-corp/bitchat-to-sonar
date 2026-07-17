#!/usr/bin/env python3
"""Aggregate content-free iOS keyboard/tail benchmark markers."""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from pathlib import Path


MARKER = "SONAR_BENCH keyboard_tail"
FIELD_RE = re.compile(r"\b([a-z_]+)=([0-9.]+)")
INTEGER_FIELDS = (
    "revisions",
    "ids_visited",
    "attach_requests",
    "ancestor_scans",
    "offset_samples",
    "viewport_shrinks",
    "tail_requests",
    "tail_executions",
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate SONAR_BENCH keyboard_tail markers from an iOS app log."
    )
    parser.add_argument("logs", nargs="+", help="App log files")
    parser.add_argument("--label", default="keyboard tail")
    parser.add_argument("--last", type=int, metavar="N")
    args = parser.parse_args()

    samples: list[dict[str, float]] = []
    for name in args.logs:
        for line in Path(name).read_text(errors="replace").splitlines():
            if MARKER not in line:
                continue
            fields = {key: float(value) for key, value in FIELD_RE.findall(line)}
            if fields.get("overlapped", 0) == 0:
                samples.append(fields)

    if args.last is not None:
        if args.last < 1:
            parser.error("--last must be greater than zero")
        samples = samples[-args.last :]
    if not samples:
        print("No complete, non-overlapping keyboard_tail samples found.", file=sys.stderr)
        return 2

    print(f"Sonar {args.label}: {len(samples)} physical keyboard transition(s)")
    print(f"{'counter / transition':28} {'median':>10} {'max':>10} {'total':>10}")
    for key in INTEGER_FIELDS:
        values = [int(sample.get(key, 0)) for sample in samples]
        print(
            f"{key:28} {statistics.median(values):>10.1f} "
            f"{max(values):>10d} {sum(values):>10d}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
