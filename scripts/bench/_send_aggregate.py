#!/usr/bin/env python3
"""Aggregate Sonar text-send markers from Apple, Android, or desktop logs.

The parser intentionally ignores platform timestamps.  The shared Rust core
emits durations as structured fields, which keeps results comparable across
os_log, logcat, and the desktop tracing formatter.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path


MARKER_RE = re.compile(
    r"send_(?:local_pending|publish_start|first_ack|publish_failed)"
)
FIELD_RE = re.compile(r"\b(message_id|event_id|local_ms|rtt_ms)=([^\s,]+)")


def percentile(values: list[int], fraction: float) -> float:
    if len(values) == 1:
        return float(values[0])
    position = fraction * (len(values) - 1)
    lower = int(position)
    upper = min(lower + 1, len(values) - 1)
    weight = position - lower
    ordered = sorted(values)
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def parse_lines(
    lines: list[str], excluded_ids: set[str] | None = None
) -> tuple[list[dict[str, int | str]], set[str]]:
    sends: dict[str, dict[str, int | str]] = {}
    excluded_ids = excluded_ids or set()

    for line in lines:
        marker_match = MARKER_RE.search(line)
        if marker_match is None:
            continue
        marker = marker_match.group(0)
        fields = dict(FIELD_RE.findall(line))
        message_id = fields.get("message_id")
        if not message_id or message_id in excluded_ids:
            continue
        send = sends.setdefault(message_id, {"message_id": message_id})
        if "event_id" in fields:
            send["event_id"] = fields["event_id"]
        if marker == "send_local_pending" and "local_ms" in fields:
            send["local_ms"] = int(fields["local_ms"])
        elif marker == "send_first_ack" and "rtt_ms" in fields:
            send["rtt_ms"] = int(fields["rtt_ms"])
        elif marker == "send_publish_failed":
            send["failed"] = 1

    complete: list[dict[str, int | str]] = []
    for send in sends.values():
        if "local_ms" not in send or "rtt_ms" not in send:
            continue
        send["total_ms"] = int(send["local_ms"]) + int(send["rtt_ms"])
        complete.append(send)
    return complete, set(sends)


def phase_summary(values: list[int]) -> dict[str, float | int]:
    return {
        "min": min(values),
        "median": statistics.median(values),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def fmt(value: float | int) -> str:
    return f"{value:.1f}" if isinstance(value, float) and value % 1 else f"{value:.0f}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate shared Sonar send_local_pending/send_first_ack markers."
    )
    parser.add_argument("logs", nargs="+", help="Log files, or - for stdin")
    parser.add_argument("--label", default="send benchmark")
    parser.add_argument(
        "--last",
        type=int,
        metavar="N",
        help="aggregate only the last N complete sends (pass rotated logs oldest first)",
    )
    parser.add_argument("--json-out", type=Path)
    parser.add_argument(
        "--exclude-json",
        action="append",
        type=Path,
        default=[],
        help=(
            "exclude every message ID observed by an earlier JSON result; "
            "repeat for multiple pre-run snapshots"
        ),
    )
    args = parser.parse_args()

    if args.last is not None and args.last < 1:
        parser.error("--last must be greater than zero")

    lines: list[str] = []
    for name in args.logs:
        if name == "-":
            lines.extend(sys.stdin)
        else:
            lines.extend(Path(name).read_text(errors="replace").splitlines())

    excluded_ids: set[str] = set()
    for path in args.exclude_json:
        payload = json.loads(path.read_text())
        observed_ids = payload.get("observed_message_ids")
        if observed_ids is None:
            observed_ids = [send["message_id"] for send in payload.get("sends", [])]
        excluded_ids.update(str(message_id) for message_id in observed_ids)

    complete, observed_ids = parse_lines(lines, excluded_ids)
    observed = len(observed_ids)
    if args.last is not None:
        complete = complete[-args.last :]
    if not complete:
        print(
            f"No complete sends found in {observed} observed send(s); "
            "need both send_local_pending local_ms= and send_first_ack rtt_ms= markers.",
            file=sys.stderr,
        )
        return 2
    failure_marked = sum(1 for send in complete if "failed" in send)

    phases = [
        ("local persist", "local_ms"),
        ("publish -> first relay ACK", "rtt_ms"),
        ("local persist + first ACK", "total_ms"),
    ]
    summaries = {
        key: phase_summary([int(send[key]) for send in complete])
        for _, key in phases
    }

    print()
    print("=" * 78)
    print(
        f"  Sonar {args.label} — {len(complete)} complete / "
        f"{observed} observed / {failure_marked} failure-marked"
    )
    print("=" * 78)
    print(f"  {'phase':32} {'min':>9} {'median':>9} {'p95':>9} {'max':>9}   (ms)")
    print("-" * 78)
    for label, key in phases:
        row = summaries[key]
        print(
            f"  {label:32} {fmt(row['min']):>9} {fmt(row['median']):>9} "
            f"{fmt(row['p95']):>9} {fmt(row['max']):>9}"
        )
    print("=" * 78)

    if args.json_out:
        payload = {
            "label": args.label,
            "complete": len(complete),
            "observed": observed,
            "observed_message_ids": sorted(observed_ids),
            "failure_marked": failure_marked,
            "phases_ms": summaries,
            "sends": complete,
        }
        args.json_out.write_text(json.dumps(payload, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
