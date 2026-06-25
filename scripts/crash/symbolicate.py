#!/usr/bin/env python3
"""
Symbolicate + summarize Apple crash reports for the Sonar iOS app.

Handles both modern JSON `.ips` reports (App Store Connect / Xcode Organizer
exports, iOS 15+) and legacy textual `.crash` reports.

For .ips it parses the JSON, finds the matching dSYM for each app-owned image
by UUID (Spotlight `mdfind`, with an Xcode Archives / DerivedData scan as a
fallback), then resolves every frame with `atos`. Crashed thread and the first
app frame ("likely crash site") are highlighted.

Usage:
    scripts/crash/symbolicate.py <report.ips | report.crash> [more...]
    scripts/crash/symbolicate.py ~/Downloads            # scan a directory
    scripts/crash/symbolicate.py                        # scan ./crashes and ~/Downloads

No third-party deps. Pure stdlib + Xcode CLI tools (atos, dwarfdump,
symbolicatecrash, mdfind).
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Image names produced by this project's archives. Frames in these images get
# symbolicated; everything else (system frameworks) is left as-is.
APP_IMAGE_NAMES = {"Sonar", "SonarNotificationService", "bitchatShareExtension"}

ARCHIVE_DIRS = [
    Path.home() / "Library/Developer/Xcode/Archives",
    Path.home() / "Library/Developer/Xcode/DerivedData",
]

_DSYM_CACHE: dict[str, str | None] = {}


def canon_uuid(u: str) -> str:
    """Normalize a UUID to canonical 8-4-4-4-12 uppercase form."""
    hexs = re.sub(r"[^0-9a-fA-F]", "", u).upper()
    if len(hexs) != 32:
        return u.upper()
    return f"{hexs[0:8]}-{hexs[8:12]}-{hexs[12:16]}-{hexs[16:20]}-{hexs[20:32]}"


def find_dsym_for_uuid(uuid: str) -> str | None:
    """Return path to the DWARF binary inside a matching .dSYM, or None."""
    u = canon_uuid(uuid)
    if u in _DSYM_CACHE:
        return _DSYM_CACHE[u]

    dsym_bundle = None
    # 1) Spotlight: Xcode indexes dSYMs by the UUIDs they contain.
    try:
        out = subprocess.run(
            ["mdfind", f"com_apple_xcode_dsym_uuids == {u}"],
            capture_output=True, text=True, timeout=20,
        ).stdout
        for line in out.splitlines():
            line = line.strip()
            if line.endswith(".dSYM") and Path(line).exists():
                dsym_bundle = line
                break
    except Exception:
        pass

    # 2) Fallback: scan archive/derived-data dSYMs and check UUIDs directly.
    if not dsym_bundle:
        dsym_bundle = _scan_archives_for_uuid(u)

    dwarf = _dwarf_binary(dsym_bundle) if dsym_bundle else None
    _DSYM_CACHE[u] = dwarf
    return dwarf


def _scan_archives_for_uuid(u: str) -> str | None:
    for root in ARCHIVE_DIRS:
        if not root.exists():
            continue
        try:
            found = subprocess.run(
                ["find", str(root), "-name", "*.dSYM"],
                capture_output=True, text=True, timeout=60,
            ).stdout.splitlines()
        except Exception:
            continue
        for d in found:
            d = d.strip()
            if not d:
                continue
            try:
                uu = subprocess.run(
                    ["dwarfdump", "--uuid", d],
                    capture_output=True, text=True, timeout=20,
                ).stdout
            except Exception:
                continue
            if u in uu.upper():
                return d
    return None


def _dwarf_binary(dsym_bundle: str) -> str | None:
    dwarf_dir = Path(dsym_bundle) / "Contents/Resources/DWARF"
    if dwarf_dir.is_dir():
        files = [p for p in dwarf_dir.iterdir() if p.is_file()]
        if files:
            return str(files[0])
    return dsym_bundle


def atos_batch(dwarf: str, arch: str, load_addr: int, addrs: list[int]) -> list[str]:
    """Resolve a batch of runtime addresses for one image."""
    cmd = ["atos", "-o", dwarf, "-arch", arch, "-l", hex(load_addr)] + [hex(a) for a in addrs]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
        return out.splitlines()
    except Exception as e:
        return [f"<atos failed: {e}>"] * len(addrs)


def load_ips(path: Path):
    """Parse a .ips report into (header, payload) dicts. Returns None if not JSON."""
    text = path.read_text(errors="replace").strip()
    # Single-object form.
    try:
        obj = json.loads(text)
        if "threads" in obj or "crashReporterKey" in obj:
            return {}, obj
    except Exception:
        pass
    # Two-part form: first line is a header JSON, remainder is the payload JSON.
    parts = text.split("\n", 1)
    if len(parts) == 2:
        try:
            header = json.loads(parts[0])
            payload = json.loads(parts[1])
            return header, payload
        except Exception:
            return None
    return None


def summarize_ips(path: Path) -> None:
    parsed = load_ips(path)
    if parsed is None:
        return summarize_legacy(path)
    header, p = parsed

    print(f"\n{'='*78}\nCRASH: {path.name}\n{'='*78}")
    app = p.get("procName") or header.get("app_name", "?")
    ver = header.get("app_version") or p.get("bundleInfo", {}).get("CFBundleShortVersionString", "?")
    build = header.get("build_version") or p.get("bundleInfo", {}).get("CFBundleVersion", "?")
    os_ver = header.get("os_version") or p.get("osVersion", {}).get("train", "?")
    print(f"app={app} version={ver} build={build}")
    print(f"os={os_ver}  device={header.get('modelCode', p.get('modelCode','?'))}  "
          f"time={header.get('timestamp', p.get('captureTime','?'))}")

    exc = p.get("exception", {})
    exc_type = exc.get("type", "?")
    signal = exc.get("signal", "")
    subtype = exc.get("subtype", "")
    print(f"\nexception: {exc_type} {signal}  {subtype}".rstrip())
    term = p.get("termination")
    if term:
        print(f"termination: {term.get('indicator','')} "
              f"(namespace={term.get('namespace','')}, code={term.get('code','')})".rstrip())
    asi = p.get("asiBacktraces") or p.get("lastExceptionBacktrace")
    if p.get("vmRegionInfo"):
        print(f"vmRegionInfo: {p['vmRegionInfo'][:200]}")

    images = p.get("usedImages", [])
    faulting = p.get("faultingThread", 0)
    threads = p.get("threads", [])

    # Pre-resolve dSYMs for app-owned images present in any frame.
    needed = set()
    for t in threads:
        for f in t.get("frames", []):
            idx = f.get("imageIndex")
            if idx is not None and 0 <= idx < len(images):
                if images[idx].get("name") in APP_IMAGE_NAMES:
                    needed.add(idx)
    dsym_for_image: dict[int, str | None] = {}
    for idx in needed:
        img = images[idx]
        dsym_for_image[idx] = find_dsym_for_uuid(img.get("uuid", ""))
        tag = "OK" if dsym_for_image[idx] else "NO dSYM"
        print(f"  dSYM[{img.get('name')}] uuid={canon_uuid(img.get('uuid',''))} -> {tag}")

    first_app_site = None
    for ti, t in enumerate(threads):
        is_crashed = t.get("triggered") or ti == faulting
        name = t.get("name") or t.get("queue") or ""
        marker = "  <-- CRASHED" if is_crashed else ""
        if not is_crashed and not _has_app_frame(t, images):
            continue  # keep output focused: crashed thread + threads with app code
        print(f"\nThread {ti}{' (' + name + ')' if name else ''}{marker}")

        frames = t.get("frames", [])
        # Group app frames by image for batched atos.
        resolved = {}
        for gi, img_idx in enumerate({f.get("imageIndex") for f in frames if f.get("imageIndex") in dsym_for_image}):
            dwarf = dsym_for_image.get(img_idx)
            if not dwarf:
                continue
            img = images[img_idx]
            arch = img.get("arch", "arm64")
            base = img.get("base", 0)
            fidxs, addrs = [], []
            for j, f in enumerate(frames):
                if f.get("imageIndex") == img_idx:
                    fidxs.append(j)
                    addrs.append(base + f.get("imageOffset", 0))
            for j, line in zip(fidxs, atos_batch(dwarf, arch, base, addrs)):
                resolved[j] = line

        for j, f in enumerate(frames):
            img_idx = f.get("imageIndex")
            img = images[img_idx] if (img_idx is not None and 0 <= img_idx < len(images)) else {}
            img_name = img.get("name", "???")
            is_app = img_name in APP_IMAGE_NAMES
            if j in resolved:
                sym = resolved[j]
            elif f.get("symbol"):
                sym = f"{f['symbol']} + {f.get('symbolLocation', 0)}"
            else:
                sym = f"0x{img.get('base',0) + f.get('imageOffset',0):x} (+{f.get('imageOffset',0)})"
            star = " *" if is_app else "  "
            print(f"{star}{j:>3}  {img_name:<28} {sym}")
            if is_app and is_crashed and first_app_site is None:
                first_app_site = (ti, j, img_name, sym)

    if first_app_site:
        ti, j, img_name, sym = first_app_site
        print(f"\n>>> LIKELY CRASH SITE (thread {ti}, frame {j}): {img_name}  {sym}")
    print()


def _has_app_frame(thread, images) -> bool:
    for f in thread.get("frames", []):
        idx = f.get("imageIndex")
        if idx is not None and 0 <= idx < len(images) and images[idx].get("name") in APP_IMAGE_NAMES:
            return True
    return False


def summarize_legacy(path: Path) -> None:
    """Legacy textual .crash: delegate to Xcode's symbolicatecrash."""
    print(f"\n{'='*78}\nCRASH (legacy text): {path.name}\n{'='*78}")
    dev = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    tool = subprocess.run(
        ["find", f"{dev}/../SharedFrameworks", "-name", "symbolicatecrash"],
        capture_output=True, text=True,
    ).stdout.splitlines()
    sym_tool = tool[0].strip() if tool else None
    if not sym_tool:
        print("symbolicatecrash not found; printing raw report.")
        print(path.read_text(errors="replace"))
        return
    env = dict(os.environ, DEVELOPER_DIR=dev)
    out = subprocess.run([sym_tool, str(path)], capture_output=True, text=True, env=env)
    print(out.stdout or out.stderr or path.read_text(errors="replace"))


def collect_paths(args: list[str]) -> list[Path]:
    paths: list[Path] = []
    targets = args or ["./crashes", str(Path.home() / "Downloads")]
    for a in targets:
        p = Path(a).expanduser()
        if p.is_dir():
            paths += sorted(p.glob("*.ips")) + sorted(p.glob("*.crash"))
        elif p.exists():
            paths.append(p)
    # Dedup, keep order.
    seen, out = set(), []
    for p in paths:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def main() -> int:
    paths = collect_paths(sys.argv[1:])
    if not paths:
        print("No .ips/.crash files found. Pass a file/dir, or drop crashes in ./crashes/.")
        return 1
    for p in paths:
        try:
            if p.suffix == ".ips":
                summarize_ips(p)
            else:
                summarize_legacy(p)
        except Exception as e:
            print(f"!! failed on {p}: {e}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
