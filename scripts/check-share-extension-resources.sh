#!/usr/bin/env bash
# Assert the iOS share extension actually ships its localized strings.
#
# The bug this pins: `bitchatShareExtension` had a Sources build phase and
# nothing else — no Resources phase, and the target was not a member of the
# `bitchatShareExtension` synchronized folder group. So
# `bitchatShareExtension/Localization/Localizable.xcstrings` never reached the
# .appex, and every `String(localized:)` in the extension rendered its raw key.
# Users saw a black sheet reading `share.status.shared_link`.
#
# This is shell rather than a unit test on purpose: iOS is not built in CI, so
# an Xcode-only guard would never run. Parsing the project file catches the
# regression on any runner in under a second.
#
# What it cannot check: whether the strings are correct, whether the catalog
# covers every key the code asks for at runtime, or whether the extension
# behaves. Those stay review questions.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PBXPROJ="ios/bitchat.xcodeproj/project.pbxproj"
CATALOG="ios/bitchatShareExtension/Localization/Localizable.xcstrings"
TARGET_NAME="bitchatShareExtension"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[ -f "$PBXPROJ" ] || fail "$PBXPROJ not found"
[ -f "$CATALOG" ] || fail "$CATALOG not found — the extension has no string catalog to ship"

python3 - "$PBXPROJ" "$TARGET_NAME" <<'PY' || exit 1
import json
import subprocess
import sys

pbxproj, target_name = sys.argv[1], sys.argv[2]

try:
    raw = subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", pbxproj],
        stderr=subprocess.STDOUT,
    )
except FileNotFoundError:
    # plutil is macOS-only. Fall back to a textual check so Linux CI still
    # catches the regression rather than silently passing.
    text = open(pbxproj, encoding="utf-8").read()
    marker = "/* %s */ = {\n\t\t\tisa = PBXNativeTarget;" % target_name
    if marker not in text:
        sys.exit("FAIL: target %s not found in project" % target_name)
    block = text.split(marker, 1)[1].split("};", 1)[0]
    if "/* Resources */" not in block:
        sys.exit(
            "FAIL: %s has no Resources build phase, so its string catalog "
            "cannot be copied into the .appex. Every String(localized:) in the "
            "extension renders its raw key." % target_name
        )
    if "fileSystemSynchronizedGroups" not in block:
        sys.exit(
            "FAIL: %s has no fileSystemSynchronizedGroups — its "
            "Localizable.xcstrings is not a target member and will not ship."
            % target_name
        )
    print("OK (textual): %s has a Resources phase + a synchronized group" % target_name)
    sys.exit(0)
except subprocess.CalledProcessError as exc:
    sys.exit("FAIL: could not parse %s: %s" % (pbxproj, exc.output.decode()))

objects = json.loads(raw)["objects"]

target = None
for obj in objects.values():
    if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == target_name:
        target = obj
        break
if target is None:
    sys.exit("FAIL: target %s not found in %s" % (target_name, pbxproj))

phases = [objects[p].get("isa") for p in target.get("buildPhases", [])]
if "PBXResourcesBuildPhase" not in phases:
    sys.exit(
        "FAIL: %s has no Resources build phase, so its string catalog cannot be "
        "copied into the .appex. Every String(localized:) in the extension will "
        "render its raw key (e.g. 'share.status.shared_link')." % target_name
    )

sync_groups = target.get("fileSystemSynchronizedGroups") or []
group_paths = [objects[g].get("path") for g in sync_groups if g in objects]
if target_name not in group_paths:
    sys.exit(
        "FAIL: %s does not include the '%s' synchronized folder group, so files "
        "added under it (including Localization/Localizable.xcstrings) are not "
        "target members." % (target_name, target_name)
    )

# The Info.plist and entitlements are consumed via build settings; copying them
# in as resources is a different kind of broken.
exceptions = []
for obj in objects.values():
    if obj.get("isa") != "PBXFileSystemSynchronizedBuildFileExceptionSet":
        continue
    if objects.get(obj.get("target", ""), {}).get("name") == target_name:
        exceptions.extend(obj.get("membershipExceptions", []))
for required in ("Info.plist", "%s.entitlements" % target_name):
    if required not in exceptions:
        sys.exit(
            "FAIL: %s must be excluded from %s's synchronized group, or it gets "
            "copied into the bundle as a resource." % (required, target_name)
        )

print("OK: %s ships a Resources phase + its synchronized string catalog" % target_name)
PY

# Every key the extension asks for at runtime must exist in the catalog. A
# missing key renders as the raw key on screen — the exact original symptom.
python3 - "$CATALOG" ios/bitchatShareExtension/ShareViewController.swift <<'PY' || exit 1
import json
import re
import sys

catalog_path, source_path = sys.argv[1], sys.argv[2]
catalog = json.load(open(catalog_path, encoding="utf-8"))
known = set(catalog.get("strings", {}))

source = open(source_path, encoding="utf-8").read()
used = set(re.findall(r'String\(localized:\s*"([^"]+)"', source))

missing = sorted(used - known)
if missing:
    sys.exit(
        "FAIL: %s asks for keys absent from the catalog: %s"
        % (source_path, ", ".join(missing))
    )

# Every locale must carry every key, or that locale falls back to the raw key.
locales = set()
for entry in catalog.get("strings", {}).values():
    locales |= set(entry.get("localizations", {}))
for key, entry in catalog.get("strings", {}).items():
    gaps = sorted(locales - set(entry.get("localizations", {})))
    if gaps:
        sys.exit("FAIL: key '%s' is missing locales: %s" % (key, ", ".join(gaps)))

print("OK: %d keys used, all present in %d locales" % (len(used), len(locales)))
PY
