#!/usr/bin/env bash
# Add Sonar's RUNTIME dependencies to a jpackage-built .deb.
#
# jpackage derives Depends only from libraries the binaries LINK against, and
# Compose Desktop 1.7.3's linux{} DSL has no way to declare extra ones (verified
# against LinuxPlatformSettings). Sonar needs two things it never links:
#
#   libsecret-tools  `secret-tool`, how DesktopSecrets reaches the Secret Service.
#                    Without it the account key -- which also derives the wallet
#                    seed -- falls back to a local file. The app surfaces that
#                    state rather than failing silently, but the right fix is for
#                    the package to pull the dependency in.
#   ffmpeg           `ffplay`, the only voice-note player Sonar will spawn. Without
#                    it a received voice note reports itself unplayable.
#
# Both are Recommends-worthy rather than Depends: the app runs, and degrades
# visibly, without either. Depends would make the package uninstallable on a
# system that cannot get them; Recommends is installed by default by apt while
# leaving that escape hatch. dpkg -i alone does NOT pull Recommends, which is why
# the app must keep surfacing the degraded state either way.
set -euo pipefail

DEB="${1:?usage: deb-add-runtime-deps.sh <path-to-deb> [outfile]}"
OUT="${2:-$DEB}"
RECOMMENDS="libsecret-tools, ffmpeg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

dpkg-deb -R "$DEB" "$WORK/pkg"
CONTROL="$WORK/pkg/DEBIAN/control"

# One path, whether or not a Recommends already exists: drop any existing field
# INCLUDING its continuation lines, then append a fresh one inside the stanza.
#
# Two hazards, both hit for real, both avoided by rewriting rather than editing:
#
#   Folded fields. Debian fields may continue across lines beginning with a space.
#   `sed s/^Recommends:.*/` rewrote only the first line and orphaned the rest,
#   which dpkg-deb -b rejects ("syntax error after reference to package"), and
#   `sed /^Depends:/a` inserted between a folded Depends and its own continuation.
#   Field order is not significant to dpkg, so neither edit-in-place was worth it.
#
#   Paragraph separation. A blank line ends the stanza, and jpackage's control
#   ends with one, so appending with `>>` started a SECOND package entry and
#   dpkg-deb refused the package. Command substitution strips every trailing
#   newline, collapsing that blank line; the printf restores exactly one.
CONTENT="$(awk '
  /^Recommends:/ { dropping = 1; next }
  dropping && /^[ \t]/ { next }
  { dropping = 0; print }
' "$CONTROL")"
printf '%s\nRecommends: %s\n' "$CONTENT" "$RECOMMENDS" > "$CONTROL"

# -Zxz matches what jpackage emits; without it dpkg-deb would repack with its
# current default and silently change the compression of a release artifact.
fakeroot dpkg-deb -Zxz -b "$WORK/pkg" "$OUT" >/dev/null

# Prove it landed rather than trusting the exit code: a sed that matched nothing
# also exits 0.
if ! dpkg-deb -f "$OUT" Recommends | grep -q 'libsecret-tools'; then
  echo "deb-add-runtime-deps: Recommends not present after repack" >&2
  exit 1
fi
echo "$(dpkg-deb -f "$OUT" Package) $(dpkg-deb -f "$OUT" Version): Recommends: $(dpkg-deb -f "$OUT" Recommends)"
