#!/usr/bin/env bash
# Assert no SwiftUI App or View reads a @StateObject's value from its init().
#
# The bug this pins: `BitchatApp.init()` did
#
#     AutoBackupBackgroundScheduler.shared.store = _sonarStore.wrappedValue
#
# Touching `_sonarStore.wrappedValue` inside `init()` forces the @StateObject's
# autoclosure to run before SwiftUI has installed the storage, so the value is
# built into a throwaway instance that SwiftUI immediately discards. The app
# then has two stores: the orphan one that connected and opened the account,
# and the view's real one, which never advanced. The build compiled perfectly
# and even logged a healthy `t1_local_paint groups=137` — from the wrong
# instance — while the UI sat on the Sonar splash forever. It shipped to a real
# phone that way.
#
# This is shell rather than an XCTest on purpose: iOS tests do not run in CI
# (#476), so an Xcode-only guard would never execute. Scanning the source
# catches the regression on any runner in well under a second.
#
# What it cannot check: whether a @StateObject is initialized correctly, any
# equivalent escape through a helper that takes the projected value, or the same
# mistake made via @ObservedObject/@State. Those stay review questions. It also
# cannot prove the app renders — that needs the UI test target tracked in #520.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

status=0

# Swift files that declare a @StateObject and an init() are the only ones that
# can hit this. Underscore-prefixed access is the property-wrapper's storage,
# which is exactly what must not be touched during init.
while IFS= read -r file; do
    grep -q "@StateObject" "$file" || continue

    # Walk the file, tracking whether we are inside an init(...) body by brace
    # depth, and flag underscore .wrappedValue reads while in there.
    awk -v f="$file" '
        /(^|[^A-Za-z0-9_])init[[:space:]]*\(/ { in_init = 1; depth = 0 }
        in_init {
            n = gsub(/\{/, "{"); depth += n
            n = gsub(/\}/, "}"); depth -= n
            if (depth > 0) started = 1
            # Strip line comments first: this file documents the very pattern it
            # forbids, and prose must not trip the guard.
            code = $0
            sub(/\/\/.*$/, "", code)
            if (match(code, /_[A-Za-z_][A-Za-z0-9_]*\.wrappedValue/)) {
                printf "%s:%d: reads %s inside init()\n", f, NR, substr(code, RSTART, RLENGTH)
                bad = 1
            }
            if (started && depth <= 0) { in_init = 0; started = 0 }
        }
        END { exit bad ? 1 : 0 }
    ' "$file" || status=1
done < <(find ios -name '*.swift' -not -path '*/build/*' 2>/dev/null)

if [[ $status -ne 0 ]]; then
    cat >&2 <<'MSG'

A @StateObject's wrappedValue is read inside init(). SwiftUI has not installed
the storage yet at that point, so this builds a throwaway instance: the object
that does the work is not the object the view observes. The symptom is a screen
that never advances while the logs look healthy.

Do the work in .task/.onAppear, or on the value SwiftUI hands the body — never
through the underscore storage in init().
MSG
    exit 1
fi

echo "OK: no @StateObject wrappedValue reads inside init()"
