#!/usr/bin/env bash
# ios-sim-type.sh — print "<device type id> <runtime id>" for a new QA or test
# simulator: the newest available iOS runtime, and the newest "iPhone N Pro"
# that runtime supports.
#
#   read -r TYPE RUNTIME < <(scripts/qa/ios-sim-type.sh)
#   xcrun simctl create "<name>" "$TYPE" "$RUNTIME"
#
# The newest device type Xcode lists is not always one the installed runtime
# can run: Xcode 27 lists an iPhone 18 Pro while iOS 26.5 supports up to the
# 17 Pro, and `simctl create` then fails.
set -euo pipefail

xcrun simctl list runtimes available -j | python3 -c '
import json, re, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")]
if not runtimes:
    sys.exit("no available iOS simulator runtime (install one in Xcode > Settings > Components)")
runtime = runtimes[-1]
pros = [d for d in runtime.get("supportedDeviceTypes", [])
        if re.fullmatch(r"iPhone \d+ Pro", d["name"])]
if not pros:
    sys.exit("runtime %s supports no iPhone Pro device type" % runtime["identifier"])
newest = max(pros, key=lambda d: int(d["name"].split()[1]))
print(newest["identifier"], runtime["identifier"])
'
