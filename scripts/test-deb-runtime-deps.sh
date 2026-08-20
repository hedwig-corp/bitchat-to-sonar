#!/usr/bin/env bash
# Fixture tests for deb-add-runtime-deps.sh.
#
# The script rewrites the control file of a release artifact and repacks 80MB of
# payload, and its only self-check is a grep after the fact. These build tiny
# .debs covering the control-file shapes it can meet, and assert the payload,
# md5sums and root ownership survive the round trip.
#
# It earns its keep: the first version inserted the field with
# `sed /^Depends:/a`, which fails on a FOLDED Depends (continuation lines
# beginning with a space) and silently does nothing when there is no Depends at
# all. Both are caught here; neither is reachable with the .deb jpackage happens
# to emit today, which is exactly why a fixture test rather than the real
# artifact.
#
# Needs dpkg-deb and fakeroot. Run: scripts/test-deb-runtime-deps.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/deb-add-runtime-deps.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
FAILED=0

mkfixture () {
  local d="$W/$1"
  mkdir -p "$d/DEBIAN" "$d/opt/sonar"
  printf 'payload\n' > "$d/opt/sonar/file"
  printf 'Package: sonar\nVersion: 0.1~alpha.1\nArchitecture: amd64\nMaintainer: Sonar <x@y>\nDescription: t\n%b' "$2" \
    > "$d/DEBIAN/control"
  printf '#!/bin/sh\nexit 0\n' > "$d/DEBIAN/postinst"
  chmod 755 "$d/DEBIAN/postinst"
  ( cd "$d" && find opt -type f -exec md5sum {} \; > DEBIAN/md5sums )
  fakeroot dpkg-deb -Zxz -b "$d" "$W/$1.deb" >/dev/null
  echo "$W/$1.deb"
}

check () {
  local label="$1" deb="$2"
  if ! "$SCRIPT" "$deb" >/dev/null 2>&1; then
    printf '  FAIL  %s: script exited non-zero\n' "$label"; FAILED=1; return
  fi
  local rec payload md5 owner
  rec="$(dpkg-deb -f "$deb" Recommends)"
  payload="$(dpkg-deb -c "$deb" | grep -c 'opt/sonar/file')"
  md5="$(dpkg-deb --ctrl-tarfile "$deb" | tar t 2>/dev/null | grep -c md5sums || true)"
  owner="$(dpkg-deb -c "$deb" | awk '/opt\/sonar\/file/{print $2}')"
  [ "$rec" = "libsecret-tools, ffmpeg" ] || { printf '  FAIL  %s: Recommends=%s\n' "$label" "$rec"; FAILED=1; return; }
  [ "$payload" = 1 ] || { printf '  FAIL  %s: payload lost\n' "$label"; FAILED=1; return; }
  [ "$md5" = 1 ] || { printf '  FAIL  %s: md5sums lost\n' "$label"; FAILED=1; return; }
  [ "$owner" = "root/root" ] || { printf '  FAIL  %s: owner=%s, not root/root\n' "$label" "$owner"; FAILED=1; return; }
  printf '  ok    %s\n' "$label"
}

check "plain Depends"            "$(mkfixture plain    'Depends: libc6\n')"
check "folded Depends"           "$(mkfixture folded   'Depends: libc6,\n libx11-6,\n zlib1g\n')"
check "pre-existing Recommends"  "$(mkfixture existing 'Depends: libc6\nRecommends: something-old\n')"
check "no Depends field"         "$(mkfixture nodeps   '')"
# The shape the real jpackage artifact has, and the one a plain `>>` broke: a
# trailing blank line ends the stanza, so appending after it creates a second
# package entry and dpkg-deb refuses the result.
check "trailing blank line"      "$(mkfixture trailing 'Depends: libc6\n\n')"

[ "$FAILED" = 0 ] || { echo "deb runtime-dep tests FAILED"; exit 1; }
echo "deb runtime-dep tests passed"
