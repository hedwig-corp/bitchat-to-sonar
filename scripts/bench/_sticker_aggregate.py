#!/usr/bin/env python3
"""Aggregate cross-platform sticker download/cache benchmark markers."""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path


MARKER_RE = re.compile(
    r"(?:device_sticker_batch_(?:begin|finished|failed)|"
    r"sticker_(?:pack_fetch|image_fetch|ref_cache_lookup|pack_prefetch_finished))"
)
FIELD_RE = re.compile(
    r"\b(purpose|source|outcome|bytes|stickers|attempted|succeeded|failed|"
    r"initial|memory|disk|refs|image_limit|image_offset|phase|"
    r"total_us|download_us|verify_us|cache_read_us|cache_write_us|pack_us)="
    r"([^\s,]+)"
)
ISO_TIMESTAMP_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))\b"
)


def timestamp_us(raw: str) -> int:
    parsed = datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc)
    delta = parsed - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return ((delta.days * 86_400 + delta.seconds) * 1_000_000) + delta.microseconds


def percentile(values: list[int], fraction: float) -> float:
    if len(values) == 1:
        return float(values[0])
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def parse_lines(lines: list[str]) -> list[dict[str, int | str]]:
    events: list[dict[str, int | str]] = []
    for line in lines:
        marker_match = MARKER_RE.search(line)
        if marker_match is None:
            continue
        event: dict[str, int | str] = {"marker": marker_match.group(0)}
        timestamp_match = ISO_TIMESTAMP_RE.match(line)
        if timestamp_match is not None:
            event["_timestamp_us"] = timestamp_us(timestamp_match.group(1))
        for key, raw in FIELD_RE.findall(line):
            value = raw.strip('"')
            event[key] = int(value) if value.isdigit() else value
        events.append(event)
    # Apple writes host and Rust markers to separate rolling files. When every
    # relevant line carries the shared RFC3339 device timestamp, merge those
    # streams chronologically instead of depending on shell/glob file order.
    if events and all("_timestamp_us" in event for event in events):
        events.sort(key=lambda event: int(event["_timestamp_us"]))
    for event in events:
        event.pop("_timestamp_us", None)
    return events


def completed_batch(
    events: list[dict[str, int | str]], *, latest_completed: bool
) -> list[dict[str, int | str]]:
    batches: list[list[dict[str, int | str]]] = []
    current: list[dict[str, int | str]] | None = None
    latest_terminal_failure: dict[str, int | str] | None = None
    for event in events:
        marker = event["marker"]
        if marker == "device_sticker_batch_begin":
            if current is not None:
                if latest_completed:
                    # A previous launcher may have crashed after begin. In
                    # rolling logs, discard that abandoned batch and let the
                    # newest begin establish the candidate run.
                    current = None
                else:
                    raise ValueError("nested/incomplete sticker benchmark batch")
            current = [event]
            latest_terminal_failure = None
        elif current is not None:
            current.append(event)
            if marker == "device_sticker_batch_failed":
                latest_terminal_failure = event
                current = None
            elif marker == "device_sticker_batch_finished":
                batches.append(current)
                latest_terminal_failure = None
                current = None
    if current is not None:
        raise ValueError("sticker benchmark batch has no finished marker")
    if latest_completed:
        if latest_terminal_failure is not None:
            phase = latest_terminal_failure.get("phase", "unknown")
            raise ValueError(f"latest sticker benchmark batch failed in phase={phase}")
        if batches:
            return batches[-1]
    if len(batches) != 1:
        raise ValueError(
            f"expected exactly one completed sticker benchmark batch, found {len(batches)}; "
            "aggregate each device/run separately"
        )
    return batches[0]


def validate_batch(
    events: list[dict[str, int | str]], *, purpose: str = "foreground"
) -> None:
    def required_int(
        event: dict[str, int | str], field: str, *, positive: bool = False
    ) -> int:
        value = event.get(field)
        marker = event.get("marker", "unknown")
        if not isinstance(value, int):
            raise ValueError(f"{marker} marker is missing integer {field}")
        if value < 0:
            raise ValueError(f"{marker} marker has negative {field}={value}")
        if positive and value == 0:
            raise ValueError(f"{marker} marker has non-positive {field}={value}")
        return value

    finished = events[-1]
    if finished.get("marker") != "device_sticker_batch_finished":
        raise ValueError("completed batch does not end with its finished marker")
    required = ("stickers", "initial", "memory", "disk", "refs")
    missing = [field for field in required if field not in finished]
    if missing:
        raise ValueError(f"batch finished marker is missing: {', '.join(missing)}")
    expected = required_int(finished, "stickers", positive=True)
    if expected <= 0:
        raise ValueError("batch reported zero stickers")
    completion_counts = {
        field: required_int(finished, field) for field in required[1:]
    }
    mismatched = {
        field: value for field, value in completion_counts.items() if value != expected
    }
    if mismatched:
        raise ValueError(
            f"incomplete batch: expected {expected} successful operations per pass, got {mismatched}"
        )

    # Validate every timing field before filtering the requested purpose. This
    # prevents a malformed prefetch report from exiting successfully merely
    # because its rows are absent from the printed foreground summary.
    timed_markers = {
        "sticker_pack_fetch",
        "sticker_image_fetch",
        "sticker_ref_cache_lookup",
    }
    for event in events[1:-1]:
        if event.get("marker") in timed_markers and event.get("purpose") not in (
            "foreground",
            "prefetch",
        ):
            raise ValueError(
                f"{event.get('marker')} marker has missing/unknown purpose={event.get('purpose')}"
            )
    def validate_images(
        image_events: list[dict[str, int | str]],
        *,
        expected_count: int,
        label: str,
        allow_memory: bool = False,
    ) -> None:
        if len(image_events) != expected_count:
            raise ValueError(
                f"{label} image marker mismatch: expected {expected_count}, found {len(image_events)}"
            )
        for event in image_events:
            source = event.get("source")
            allowed_sources = ("network", "disk", "shared") + ("memory",) * allow_memory
            if source not in allowed_sources:
                raise ValueError(f"{label} image marker has unknown source={source}")
            required_int(event, "bytes", positive=True)
            required_int(event, "total_us")
            if source == "network":
                for field in ("download_us", "verify_us", "cache_write_us"):
                    required_int(event, field)
            elif source == "disk":
                required_int(event, "cache_read_us")

    def validate_foreground() -> None:
        phase_events = [
            event for event in events[1:-1] if event.get("purpose") == "foreground"
        ]
        packs = [
            event for event in phase_events if event.get("marker") == "sticker_pack_fetch"
        ]
        if len(packs) != 1:
            raise ValueError(
                f"expected exactly one foreground pack marker, found {len(packs)}"
            )
        pack = packs[0]
        if pack.get("source") not in ("network", "fallback_disk", "shared"):
            raise ValueError(f"pack marker has unknown source={pack.get('source')}")
        required_int(pack, "stickers", positive=True)
        required_int(pack, "total_us")

        images = [
            event for event in phase_events if event.get("marker") == "sticker_image_fetch"
        ]
        # The three foreground passes are initial durable, host memory, and
        # post-memory durable. Requiring the last pass to be disk proves that
        # the persistent cache—not another network download—was exercised.
        validate_images(
            images, expected_count=expected * 3, label="foreground", allow_memory=True
        )
        memory = sum(event.get("source") == "memory" for event in images)
        durable = sum(event.get("source") in ("network", "disk", "shared") for event in images)
        final_disk = sum(event.get("source") == "disk" for event in images[-expected:])
        refs = [
            event
            for event in phase_events
            if event.get("marker") == "sticker_ref_cache_lookup"
        ]
        for event in refs:
            if event.get("outcome") != "hit":
                raise ValueError(
                    "foreground transcript lookup was not a hit: "
                    f"outcome={event.get('outcome')}"
                )
            required_int(event, "bytes", positive=True)
            required_int(event, "total_us")
        observed = {
            "memory markers": memory,
            "durable/shared markers": durable,
            "final disk markers": final_disk,
            "ref hits": len(refs),
        }
        wanted = {
            "memory markers": expected,
            "durable/shared markers": expected * 2,
            "final disk markers": expected,
            "ref hits": expected,
        }
        if observed != wanted:
            raise ValueError(f"marker count mismatch: expected {wanted}, got {observed}")

    def validate_prefetch(*, required: bool) -> None:
        prefetch_events = [event for event in events[1:-1] if event.get("purpose") == "prefetch"]
        if not prefetch_events:
            if required:
                raise ValueError("prefetch purpose requested but no prefetch markers found")
            return
        packs = [
            event for event in prefetch_events if event.get("marker") == "sticker_pack_fetch"
        ]
        if len(packs) != 1:
            raise ValueError(f"expected exactly one prefetch pack marker, found {len(packs)}")
        if packs[0].get("source") not in ("network", "fallback_disk", "shared"):
            raise ValueError(f"prefetch pack marker has unknown source={packs[0].get('source')}")
        required_int(packs[0], "stickers", positive=True)
        required_int(packs[0], "total_us")
        finished = [
            event
            for event in prefetch_events
            if event.get("marker") == "sticker_pack_prefetch_finished"
        ]
        if len(finished) != 1:
            raise ValueError(
                f"expected exactly one prefetch completion marker, found {len(finished)}"
            )
        summary = finished[0]
        attempted = required_int(summary, "attempted")
        succeeded = required_int(summary, "succeeded")
        failed = required_int(summary, "failed")
        required_int(summary, "pack_us")
        required_int(summary, "total_us")
        if attempted != succeeded + failed:
            raise ValueError(
                f"prefetch counts do not balance: attempted={attempted}, "
                f"succeeded={succeeded}, failed={failed}"
            )
        if failed != 0:
            raise ValueError(f"prefetch reported failed={failed}")
        images = [
            event
            for event in prefetch_events if event.get("marker") == "sticker_image_fetch"
        ]
        validate_images(images, expected_count=succeeded, label="prefetch")

    if purpose in ("foreground", "all"):
        validate_foreground()
    if purpose in ("prefetch", "all"):
        validate_prefetch(required=purpose == "prefetch")


def summary_us(values: list[int]) -> dict[str, float | int]:
    return {
        "count": len(values),
        "min_us": min(values),
        "median_us": statistics.median(values),
        "p95_us": percentile(values, 0.95),
        "max_us": max(values),
    }


def fmt_ms(value_us: float | int) -> str:
    value_ms = float(value_us) / 1000.0
    if value_ms < 0.01:
        return f"{value_ms:.3f}"
    if value_ms < 10:
        return f"{value_ms:.2f}"
    return f"{value_ms:.1f}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Aggregate SONAR_BENCH sticker pack, HTTPS, disk-cache, and "
            "validated transcript-cache timings."
        )
    )
    parser.add_argument("logs", nargs="+", help="Log files, or - for stdin")
    parser.add_argument("--label", default="sticker benchmark")
    parser.add_argument(
        "--purpose",
        choices=("all", "foreground", "prefetch"),
        default="foreground",
        help="filter pack/image events by caller purpose",
    )
    parser.add_argument("--json-out", type=Path)
    parser.add_argument(
        "--latest-completed",
        action="store_true",
        help=(
            "select the newest successful batch from timestamped rolling logs; "
            "reject a newer failed/incomplete run"
        ),
    )
    args = parser.parse_args()

    lines: list[str] = []
    for name in args.logs:
        if name == "-":
            lines.extend(sys.stdin)
        else:
            lines.extend(Path(name).read_text(errors="replace").splitlines())

    try:
        events = completed_batch(
            parse_lines(lines), latest_completed=args.latest_completed
        )
        validate_batch(events, purpose=args.purpose)
    except ValueError as error:
        print(f"Invalid sticker benchmark: {error}", file=sys.stderr)
        return 2
    # Batch boundaries are control records, not timing samples.
    events = events[1:-1]
    if args.purpose != "all":
        events = [
            event
            for event in events
            if event.get("purpose") == args.purpose
        ]
    if not events:
        print("No sticker benchmark markers found.", file=sys.stderr)
        return 2

    phases: list[tuple[str, list[int]]] = []

    def values(marker: str, field: str, **matches: str) -> list[int]:
        return [
            int(event[field])
            for event in events
            if event.get("marker") == marker
            and field in event
            and all(event.get(key) == value for key, value in matches.items())
        ]

    phases.extend(
        [
            (
                "pack metadata relay fetch",
                values("sticker_pack_fetch", "total_us", source="network"),
            ),
            (
                "validated pack relay-failure fallback",
                values("sticker_pack_fetch", "total_us", source="fallback_disk"),
            ),
            (
                "shared pack fetch result",
                values("sticker_pack_fetch", "total_us", source="shared"),
            ),
            (
                "HTTPS image fetch total",
                values("sticker_image_fetch", "total_us", source="network"),
            ),
            (
                "HTTPS response download",
                values("sticker_image_fetch", "download_us", source="network"),
            ),
            (
                "download SHA-256 verify",
                values("sticker_image_fetch", "verify_us", source="network"),
            ),
            (
                "disk write + budget check",
                values("sticker_image_fetch", "cache_write_us", source="network"),
            ),
            (
                "verified image disk hit",
                values("sticker_image_fetch", "total_us", source="disk"),
            ),
            (
                "shared image fetch result",
                values("sticker_image_fetch", "total_us", source="shared"),
            ),
            (
                "host memory hit",
                values("sticker_image_fetch", "total_us", source="memory"),
            ),
            (
                "validated transcript hit",
                values("sticker_ref_cache_lookup", "total_us", outcome="hit"),
            ),
            (
                "validated transcript miss",
                values("sticker_ref_cache_lookup", "total_us", outcome="miss"),
            ),
            (
                "pack prefetch batch",
                values("sticker_pack_prefetch_finished", "total_us"),
            ),
        ]
    )
    summaries = {label: summary_us(samples) for label, samples in phases if samples}

    print()
    print("=" * 86)
    print(f"  Sonar {args.label} — {len(events)} marker(s), purpose={args.purpose}")
    print("=" * 86)
    print(f"  {'phase':34} {'n':>5} {'min':>9} {'median':>9} {'p95':>9} {'max':>9}   (ms)")
    print("-" * 86)
    for label, samples in phases:
        if not samples:
            continue
        row = summaries[label]
        print(
            f"  {label:34} {row['count']:>5} "
            f"{fmt_ms(row['min_us']):>9} {fmt_ms(row['median_us']):>9} "
            f"{fmt_ms(row['p95_us']):>9} {fmt_ms(row['max_us']):>9}"
        )
    print("=" * 86)

    network = summaries.get("HTTPS image fetch total")
    disk = summaries.get("verified image disk hit")
    memory = summaries.get("host memory hit")
    validated = summaries.get("validated transcript hit")
    if network and disk and float(disk["median_us"]) > 0:
        ratio = float(network["median_us"]) / float(disk["median_us"])
        print(f"  median network→disk cache speedup: {ratio:.1f}x")
    if network and validated and float(validated["median_us"]) > 0:
        ratio = float(network["median_us"]) / float(validated["median_us"])
        print(f"  median network→validated transcript speedup: {ratio:.1f}x")
    if network and memory and float(memory["median_us"]) > 0:
        ratio = float(network["median_us"]) / float(memory["median_us"])
        print(f"  median network→host memory speedup: {ratio:.1f}x")

    prefetches = [
        event for event in events if event.get("marker") == "sticker_pack_prefetch_finished"
    ]
    if prefetches:
        attempted = sum(int(event.get("attempted", 0)) for event in prefetches)
        succeeded = sum(int(event.get("succeeded", 0)) for event in prefetches)
        failed = sum(int(event.get("failed", 0)) for event in prefetches)
        print(
            f"  prefetch images: attempted={attempted} succeeded={succeeded} failed={failed}"
        )

    if args.json_out:
        args.json_out.write_text(
            json.dumps(
                {
                    "label": args.label,
                    "purpose": args.purpose,
                    "markers": len(events),
                    "phases": summaries,
                    "events": events,
                },
                indent=2,
            )
            + "\n"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
