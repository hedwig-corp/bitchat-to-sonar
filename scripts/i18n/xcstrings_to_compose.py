#!/usr/bin/env python3
"""Convert iOS Localizable.xcstrings into Compose Multiplatform string resources.

Reads ios/bitchat/Localizable.xcstrings (single source of truth) and writes
apps/sonar/composeApp/src/commonMain/composeResources/values*/strings.xml
plus a stable id map at scripts/i18n/string_id_map.json.

Usage:
  python3 scripts/i18n/xcstrings_to_compose.py          # write resources
  python3 scripts/i18n/xcstrings_to_compose.py --check  # diff against committed output
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
XCSTRINGS_PATH = REPO_ROOT / "ios" / "bitchat" / "Localizable.xcstrings"
OUT_ROOT = (
    REPO_ROOT
    / "apps"
    / "sonar"
    / "composeApp"
    / "src"
    / "commonMain"
    / "composeResources"
)
ID_MAP_PATH = Path(__file__).resolve().parent / "string_id_map.json"

# xcstrings lang code -> Android/Compose values-dir qualifier (None = default `values`)
LOCALE_QUALIFIER: dict[str, str | None] = {
    "en": None,
    "ar": "ar",
    "bn": "bn",
    "de": "de",
    "es": "es",
    "fil": "fil",
    "fr": "fr",
    "he": "he",
    "hi": "hi",
    "id": "id",
    "it": "it",
    "ja": "ja",
    "ko": "ko",
    "ms": "ms",
    "ne": "ne",
    "nl": "nl",
    "pl": "pl",
    "pt": "pt",
    "ru": "ru",
    "sv": "sv",
    "ta": "ta",
    "th": "th",
    "tr": "tr",
    "uk": "uk",
    "ur": "ur",
    "vi": "vi",
    "pt-BR": "pt-rBR",
    # Compose Multiplatform 1.7.3 does NOT support the BCP-47 "b+lang+Script"
    # qualifier form (it rejects it with "unknown qualifier"). Use the Android
    # language+region form instead: Simplified Chinese -> CN, Traditional -> TW.
    "zh-Hans": "zh-rCN",
    "zh-Hant": "zh-rTW",
}

AUTO_HEADER = (
    "<!-- AUTO-GENERATED from ios/bitchat/Localizable.xcstrings by "
    "scripts/i18n/xcstrings_to_compose.py. DO NOT EDIT. -->"
)

_NON_ALNUM = re.compile(r"[^a-z0-9]+")

# Kotlin hard keywords (KEYWORDS in the grammar) that cannot be used as a bare
# identifier without backtick escaping. Soft/modifier keywords are fine.
_KOTLIN_HARD_KEYWORDS = frozenset({
    "as", "break", "class", "continue", "do", "else", "false", "for", "fun",
    "if", "in", "interface", "is", "null", "object", "package", "return",
    "super", "this", "throw", "true", "try", "typealias", "typeof", "val",
    "var", "when", "while",
})
_FORMAT_POSITIONAL = re.compile(r"%(\d+)\$@")
_VALID_ID = re.compile(r"^[a-z][a-z0-9_]*$")

# Apple stringsdict plural/variable reference, e.g. %#@people@ or %2$#@count@.
# This syntax is meaningless on Android/Java formatting (it would render
# literally or throw IllegalFormatException), so such keys are skipped rather
# than emitted as broken resources. Proper handling means Android <plurals>,
# which is tracked follow-up work.
_APPLE_VAR_REF = re.compile(r"%(?:\d+\$)?#@")


def slugify(english_key: str) -> str:
    """Derive a snake_case resource id stub from the English key text."""
    s = english_key.lower()
    s = _NON_ALNUM.sub("_", s)
    s = s.strip("_")
    s = re.sub(r"_+", "_", s)
    if len(s) > 40:
        cut = s[:40]
        if "_" in cut:
            cut = cut.rsplit("_", 1)[0]
        s = cut.rstrip("_")
    return s


def mint_id(english_key: str, used_ids: set[str], empty_counter: list[int]) -> str:
    """Mint a new unique Android resource id for english_key."""
    base = slugify(english_key)
    if not base:
        empty_counter[0] += 1
        base = f"str_{empty_counter[0]}"
    if base[0].isdigit():
        base = f"s_{base}"
    # Avoid Kotlin hard keywords: the Compose Resources accessor is a Kotlin
    # `val <id>`, and a bare keyword would force backtick escaping at every call
    # site (e.g. Res.string.`continue`). Append `_` to keep call sites clean.
    if base in _KOTLIN_HARD_KEYWORDS:
        base = f"{base}_"
    candidate = base
    n = 2
    while candidate in used_ids:
        candidate = f"{base}_{n}"
        n += 1
    if not _VALID_ID.match(candidate):
        raise ValueError(f"invalid resource id {candidate!r} for key {english_key!r}")
    used_ids.add(candidate)
    return candidate


def load_id_map(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"id map must be an object: {path}")
    return {str(k): str(v) for k, v in data.items()}


def assign_ids(keys: list[str], existing: dict[str, str]) -> dict[str, str]:
    """Reuse persisted ids; mint only for new keys. Never reassign."""
    used: set[str] = set()
    # Preserve ids for keys we still have; track collisions from the map.
    result: dict[str, str] = {}
    for key in keys:
        if key in existing:
            rid = existing[key]
            if rid in used:
                raise SystemExit(
                    f"duplicate id {rid!r} in existing map for key {key!r}"
                )
            if not _VALID_ID.match(rid):
                raise SystemExit(f"invalid persisted id {rid!r} for key {key!r}")
            used.add(rid)
            result[key] = rid

    # Highest str_<n> already used (from map or previous empty slugs).
    empty_counter = [0]
    for rid in used:
        m = re.fullmatch(r"str_(\d+)", rid)
        if m:
            empty_counter[0] = max(empty_counter[0], int(m.group(1)))

    for key in keys:
        if key in result:
            continue
        result[key] = mint_id(key, used, empty_counter)
    return result


def convert_format_specifiers(value: str) -> str:
    """Map Apple %@ / %n$@ to Android %s / %n$s before XML escaping."""
    value = _FORMAT_POSITIONAL.sub(r"%\1$s", value)
    value = value.replace("%@", "%s")
    return value


def escape_android_value(value: str) -> str:
    """Escape a string for Android strings.xml text content."""
    value = convert_format_specifiers(value)
    value = (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("'", r"\'")
        .replace('"', r"\"")
        .replace("\r\n", r"\n")
        .replace("\n", r"\n")
        .replace("\r", r"\n")
    )
    # A leading @ or ? makes Android read the value as a resource / theme-attr
    # reference; escape it so the literal character survives.
    if value[:1] in ("@", "?"):
        value = "\\" + value
    if value[:1].isspace() or value[-1:].isspace():
        value = f'"{value}"'
    return value


def localization_value(entry: dict, lang: str) -> str | None:
    locs = entry.get("localizations") or {}
    loc = locs.get(lang)
    if not loc:
        return None
    unit = loc.get("stringUnit") or {}
    if "value" not in unit:
        return None
    return unit["value"]


def english_value(key: str, entry: dict) -> str:
    en = localization_value(entry, "en")
    if en is not None:
        return en
    return key


def values_dir_name(qualifier: str | None) -> str:
    if qualifier is None:
        return "values"
    return f"values-{qualifier}"


def emit_strings_xml(items: list[tuple[str, str]]) -> str:
    """Emit a complete strings.xml document. items already sorted by id."""
    # Well-formed XML requires the prolog before any content. The AUTO-GENERATED
    # marker is the first comment line immediately after the declaration so
    # ElementTree (and Android) can parse the file.
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        AUTO_HEADER,
        "<resources>",
    ]
    for rid, value in items:
        lines.append(f'    <string name="{rid}">{escape_android_value(value)}</string>')
    lines.append("</resources>")
    lines.append("")
    return "\n".join(lines)


def collect_by_locale(
    strings: dict[str, dict], id_map: dict[str, str]
) -> dict[str | None, list[tuple[str, str]]]:
    """Map qualifier (None=default) -> sorted list of (id, value)."""
    by_qual: dict[str | None, list[tuple[str, str]]] = {None: []}

    for key in sorted(strings.keys(), key=lambda k: id_map[k]):
        entry = strings[key]
        rid = id_map[key]
        # Default English always includes every key.
        by_qual.setdefault(None, []).append((rid, english_value(key, entry)))

        locs = entry.get("localizations") or {}
        for lang, loc in locs.items():
            if lang == "en":
                continue
            if lang not in LOCALE_QUALIFIER:
                raise SystemExit(f"unknown language code in xcstrings: {lang!r}")
            unit = (loc or {}).get("stringUnit") or {}
            if "value" not in unit:
                continue
            qual = LOCALE_QUALIFIER[lang]
            by_qual.setdefault(qual, []).append((rid, unit["value"]))

    for qual in by_qual:
        by_qual[qual].sort(key=lambda pair: pair[0])
    return by_qual


def write_resources(
    out_root: Path, by_qual: dict[str | None, list[tuple[str, str]]]
) -> list[Path]:
    written: list[Path] = []
    for qual, items in sorted(
        by_qual.items(), key=lambda kv: (kv[0] is not None, kv[0] or "")
    ):
        dir_path = out_root / values_dir_name(qual)
        dir_path.mkdir(parents=True, exist_ok=True)
        path = dir_path / "strings.xml"
        path.write_text(emit_strings_xml(items), encoding="utf-8")
        written.append(path)
    return written


def write_id_map(path: Path, id_map: dict[str, str]) -> None:
    ordered = {k: id_map[k] for k in sorted(id_map.keys())}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def generate(out_root: Path, id_map_path: Path) -> tuple[list[Path], dict[str, str], int]:
    with XCSTRINGS_PATH.open(encoding="utf-8") as f:
        catalog = json.load(f)
    strings: dict[str, dict] = catalog["strings"]

    # Drop keys carrying Apple plural/variable references — they cannot be
    # represented as a flat Android string resource. Skipping keeps broken
    # format syntax out of the generated files; migrating them to <plurals> is
    # tracked follow-up work.
    skipped = sorted(
        k for k, e in strings.items() if _APPLE_VAR_REF.search(english_value(k, e))
    )
    if skipped:
        strings = {k: v for k, v in strings.items() if k not in skipped}
        print(
            f"skipped {len(skipped)} key(s) with Apple plural/variable refs "
            f"(need Android <plurals>): {', '.join(repr(k) for k in skipped)}",
            file=sys.stderr,
        )
    keys = sorted(strings.keys())
    existing = load_id_map(id_map_path)
    # When generating into a temp tree for --check, still load the committed map.
    committed_map = load_id_map(ID_MAP_PATH) if id_map_path != ID_MAP_PATH else existing
    if id_map_path != ID_MAP_PATH:
        existing = committed_map

    id_map = assign_ids(keys, existing)
    by_qual = collect_by_locale(strings, id_map)
    written = write_resources(out_root, by_qual)
    write_id_map(id_map_path, id_map)
    return written, id_map, len(by_qual[None])


def check_mode() -> int:
    """Generate into a temp dir and diff against committed output + id map."""
    with tempfile.TemporaryDirectory(prefix="xcstrings_to_compose_") as tmp:
        tmp_path = Path(tmp)
        out_root = tmp_path / "composeResources"
        id_map_path = tmp_path / "string_id_map.json"
        generate(out_root, id_map_path)

        diffs: list[str] = []

        # Compare id map
        committed_map = ID_MAP_PATH.read_text(encoding="utf-8") if ID_MAP_PATH.is_file() else ""
        generated_map = id_map_path.read_text(encoding="utf-8")
        if committed_map != generated_map:
            diffs.append(f"diff: {ID_MAP_PATH.relative_to(REPO_ROOT)}")

        # Compare every generated strings.xml against committed counterparts;
        # also flag committed locale files missing from generation.
        gen_files = {p.relative_to(out_root): p for p in out_root.glob("values*/strings.xml")}
        committed_files = {
            p.relative_to(OUT_ROOT): p for p in OUT_ROOT.glob("values*/strings.xml")
        }

        for rel in sorted(set(gen_files) | set(committed_files)):
            g = gen_files.get(rel)
            c = committed_files.get(rel)
            if g is None:
                diffs.append(f"extra committed: {OUT_ROOT.relative_to(REPO_ROOT) / rel}")
                continue
            if c is None:
                diffs.append(f"missing committed: {OUT_ROOT.relative_to(REPO_ROOT) / rel}")
                continue
            if g.read_text(encoding="utf-8") != c.read_text(encoding="utf-8"):
                diffs.append(f"diff: {OUT_ROOT.relative_to(REPO_ROOT) / rel}")

        if diffs:
            print("xcstrings_to_compose --check FAILED:", file=sys.stderr)
            for line in diffs:
                print(f"  {line}", file=sys.stderr)
            return 1
        print("xcstrings_to_compose --check OK")
        return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate Compose string resources from Localizable.xcstrings"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="generate to a temp dir and exit 1 if committed output differs",
    )
    args = parser.parse_args(argv)

    if args.check:
        return check_mode()

    # Clean previous generated values* trees so removed locales do not linger.
    if OUT_ROOT.is_dir():
        for child in OUT_ROOT.iterdir():
            if child.is_dir() and child.name.startswith("values"):
                shutil.rmtree(child)

    written, id_map, default_count = generate(OUT_ROOT, ID_MAP_PATH)
    print(f"files_written={len(written)}")
    print(f"ids_minted={len(id_map)}")
    print(f"default_key_count={default_count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
