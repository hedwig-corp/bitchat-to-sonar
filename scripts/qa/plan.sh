#!/usr/bin/env bash
# plan.sh — which QA a change needs, and which of it this machine can run.
# The entry point of the `qa-run` skill (.agents/skills/qa-run/SKILL.md), for
# any contributor's agent; a human can read the output just as well.
#
#   scripts/qa/plan.sh [--base <ref>] [--head <ref>]
#   (base defaults to origin/main, else main; head to the working tree)
#
# Reads the diff against the merge-base with <ref> plus uncommitted and
# untracked files, maps the paths to QA areas and registry sections
# (docs/QA-SCENARIOS.md), checks the toolchain and gitignored config
# (presence only — never values), and prints three lists:
#   RUN      commands, in tier order, that this machine can run
#   NOT RUN  what the change needs but this machine cannot run, and why
#   WALK     registry sections to walk by hand on the platforms in RUN
# The NOT RUN lines go into the QA report as they are. Read-only: it builds,
# boots and installs nothing.
set -uo pipefail
shopt -s nocasematch

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2
BASE=""; HEAD_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="${2:?--base <ref>}"; shift 2 ;;
    --head) HEAD_REF="${2:?--head <ref>}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$BASE" ]]; then
  if git rev-parse -q --verify origin/main >/dev/null; then BASE=origin/main; else BASE=main; fi
fi
MB="$(git merge-base "${HEAD_REF:-HEAD}" "$BASE" 2>/dev/null)" || { echo "no merge-base with $BASE" >&2; exit 2; }

if [[ -n "$HEAD_REF" ]]; then
  changed="$(git diff --name-only "$MB" "$HEAD_REF")"
else
  changed="$( { git diff --name-only "$MB"; git diff --name-only; git ls-files --others --exclude-standard; } | sort -u)"
fi
[[ -n "$changed" ]] || { echo "no changes against $BASE"; exit 0; }

# --- areas -----------------------------------------------------------------
ios=0 android=0 core=0 corelib=0 wallet=0 breez=0 messaging=0 share=0 localtime=0
ui=0 i18n=0 perf=0 transcript=0 code=0 harness=0 ffi=0 mirror_kt=0 mirror_swift=0 slow=0
while IFS= read -r f; do
  b="${f##*/}"   # keyword areas match the file name: every Compose path contains "chat/bitchat"
  case "$f" in
    ios/*) ios=1; code=1 ;;
    apps/sonar/*) android=1; code=1 ;;
    core/*) core=1; ios=1; android=1; code=1 ;;
    packages/transcript-engine*|ios/localPackages/TranscriptEngine/*) transcript=1; messaging=1; code=1 ;;
  esac
  case "$f" in core/sonar-core/src/*) corelib=1 ;; esac
  case "$f" in scripts/qa/*) harness=1 ;; esac
  case "$f" in core/sonar-ffi/src/*) ffi=1 ;; esac
  case "$b" in SonarAppState.kt) mirror_kt=1 ;; SonarAppStore.swift) mirror_swift=1 ;; esac
  case "$f" in core/sonar-wallet*|*/wallet/*|*SonarWalletKit*) wallet=1 ;; esac
  case "$b" in *wallet*|*cashu*|*breez*|*unify*|*SonarPay*|*payment*) wallet=1 ;; esac
  case "$f" in core/sonar-wallet-breez/*) breez=1 ;; esac
  case "$b" in *breez*) breez=1 ;; esac
  case "$f" in core/sonar-core/src/client.rs) messaging=1 ;; esac
  case "$b" in
    SonarAppState.kt|SonarAppStore.swift|MarmotChatView.swift|\
    *conversation*|*transcript*|*message*|*chat*|*unread*|*marmot*|*reaction*|*notification*) messaging=1 ;;
  esac
  case "$f" in ios/bitchatShareExtension/*) share=1 ;; esac
  case "$b" in *share*) share=1 ;; esac
  case "$b" in *localtime*|*local_time*|*timezone*) localtime=1 ;; esac
  # A lost publish only shows up when the network breaks mid-send: QA_SLOW=1
  # runs QA-142 (airplane mode until the outbox gives up on a share).
  case "$b" in outbox.rs|conversation_index.rs|*timezone*|*localtime*|*local_time*) slow=1 ;; esac
  case "$f" in core/sonar-core/src/client.rs) slow=1 ;; esac
  case "$f" in ios/bitchat/Views/*|*/screens/*|*/ui/*) ui=1 ;; esac
  case "$b" in *Screen.kt|*View.swift|*Sheet*) ui=1 ;; esac
  case "$f" in *Localizable.xcstrings|scripts/i18n/*|*/composeResources/*strings*) i18n=1; ui=1 ;; esac
  case "$b" in *startup*|*coldstart*|*bench*|*relay*|*sync*|*background*) perf=1 ;; esac
done <<< "$changed"

# --- environment -----------------------------------------------------------
os="$(uname -s)"
have() { command -v "$1" >/dev/null 2>&1; }
jdk=0; java -version >/dev/null 2>&1 && jdk=1   # macOS ships a /usr/bin/java stub without a JDK
SDK=""
for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
         "$(sed -n 's/^sdk\.dir=//p' apps/sonar/local.properties 2>/dev/null)" \
         "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
  [[ -n "$d" && -d "$d" ]] && { SDK="$d"; break; }
done
avds=""; [[ -x "$SDK/emulator/emulator" ]] && avds="$("$SDK/emulator/emulator" -list-avds 2>/dev/null | tr '\n' ' ')"
ndk=0; [[ -n "${ANDROID_NDK_HOME:-}" || -d "$SDK/ndk" ]] && ndk=1
xcode=0; [[ "$os" == Darwin ]] && xcodebuild -version >/dev/null 2>&1 && xcrun simctl list devices >/dev/null 2>&1 && xcode=1
cli=0; [[ -x core/target/release/sonar-cli ]] && cli=1
breez_key=0
{ [[ -n "${BREEZ_API_KEY:-}" ]] ||
  grep -Eq '^[[:space:]]*breez\.apiKey[[:space:]]*=[[:space:]]*[^[:space:]]' apps/sonar/local.properties 2>/dev/null ||
  grep -Eq '^[[:space:]]*BREEZ_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]' ios/Configs/Local.xcconfig 2>/dev/null; } && breez_key=1

echo "base: $BASE ($(git rev-parse --short "$MB")) · $(wc -l <<< "$changed" | tr -d ' ') changed files"
areas=""
for a in core ffi wallet breez messaging transcript share localtime ui i18n perf harness; do
  (( ${!a} )) && areas+=" $a"
done
printf 'areas:%s' "${areas:- (none)}"
printf ' · platforms:'; (( ios )) && printf ' ios'; (( android )) && printf ' android'; (( code )) || printf ' none (no app or core code)'
echo; echo
echo "machine: $os · rust $(have cargo && echo yes || echo NO) · jdk $([[ $jdk == 1 ]] && echo yes || echo NO)" \
     "· android-sdk $([[ -n $SDK ]] && echo yes || echo NO) · avds: ${avds:-none} · ndk $([[ $ndk == 1 ]] && echo yes || echo NO)" \
     "· xcode $([[ $xcode == 1 ]] && echo yes || echo NO) · sonar-cli $([[ $cli == 1 ]] && echo built || echo 'not built')"
echo "config (presence only): breez key $([[ $breez_key == 1 ]] && echo yes || echo no)" \
     "· google-services.json $([[ -f apps/sonar/composeApp/google-services.json ]] && echo yes || echo no)" \
     "· GoogleService-Info.plist $([[ -f ios/bitchat/GoogleService-Info.plist ]] && echo yes || echo no)" \
     "· cdk-mintd $(have cdk-mintd && echo yes || echo no)"
echo

RUN=() NOT=() WALK=()
run() { RUN+=("$1"); }
not() { NOT+=("$1"); }

build_core=0   # the iOS app links sonarffi.xcframework, built from core/ (gitignored)
[[ -d ios/localPackages/SonarCore/Frameworks/sonarffi.xcframework ]] || build_core=1
(( core )) && build_core=1

# Tier 0 — static checks CI runs on every PR (seconds, any OS).
run "T0  scripts/check-regression-ledger.sh"
run "T0  scripts/check-rng-hygiene.sh"
(( ios )) && run "T0  scripts/check-stateobject-init.sh"
(( share && ios )) && run "T0  scripts/check-share-extension-resources.sh"
(( i18n )) && run "T0  python3 scripts/i18n/xcstrings_to_compose.py --check"
if (( ffi )); then
  # CI rebuilds the iOS core and fails on any drift in the committed bindings.
  # A doc-comment edit on an exported item changes them too.
  if (( xcode )) && have cargo; then
    run "T1  core/build-ios.sh && git diff --exit-code -- ios/localPackages/SonarCore/Sources/SonarFFI.swift   # commit the regenerated file"
  else
    not "Swift bindings drift check: core/sonar-ffi changed, and regenerating SonarFFI.swift needs macOS + Xcode + Rust; CI will run it"
  fi
fi

# Tier 1 — unit and UI tests at the call site (minutes).
if (( core )); then
  if have cargo; then
    run "T1  (cd core && cargo test --workspace)"
    (( corelib )) && run "T1  scripts/qa/core-flake-check.sh --runs 5        # QA-125"
    if (( breez )); then
      have protoc && run "T1  (cd core/sonar-wallet-breez && cargo test --locked)" \
                  || not "Breez island tests (core/sonar-wallet-breez): protoc not installed"
    fi
  else
    not "core unit tests: Rust (cargo) not installed — https://rustup.rs"
  fi
fi
if (( android )); then
  (( jdk )) && have cargo && run "T1  (cd apps/sonar && ./gradlew :composeApp:jvmTest)" \
            || not "Compose jvmTest: needs JDK 17 and Rust"
fi
if (( transcript )); then
  (( xcode )) && run "T1  (cd ios/localPackages/TranscriptEngine && swift test)" \
              || not "TranscriptEngine swift test: needs macOS + Xcode"
fi
if (( ios )); then
  if (( xcode )) && (( build_core )) && ! have cargo; then
    not "iOS unit tests and every iOS scenario: sonarffi.xcframework must be built from core/, which needs Rust (cargo)"
  elif (( xcode )); then
    run "T1  iOS unit suite on a SECOND simulator (not the QA one): qa-run skill, step 3$([[ $build_core == 1 ]] && echo ' — after ios-setup.sh --build-core below')"
  else
    not "iOS unit tests and every iOS scenario: needs macOS + Xcode (license accepted: sudo xcodebuild -license)"
  fi
fi

# Tier 2 — end-to-end on a dedicated emulator/simulator against sonar-cli peers.
peers=1
if (( code && ! cli )); then
  if have cargo; then
    run "T2  cargo build -p sonar-cli --release --manifest-path core/Cargo.toml   # the peers"
  else
    peers=0; not "every end-to-end scenario: the sonar-cli peers need Rust (cargo) to build"
  fi
fi
cfg=""; (( breez_key )) && [[ -f apps/sonar/composeApp/google-services.json ]] || cfg=" --allow-missing-config"
if (( android && peers )); then
  if [[ -z "$SDK" ]]; then
    not "Android end-to-end: no Android SDK found (set ANDROID_HOME)"
  elif [[ -z "$avds" ]]; then
    not "Android end-to-end: no AVD — create one (android-setup.sh header), then re-run plan.sh"
  elif (( ! ndk )) || ! have cargo-ndk; then
    not "Android end-to-end: the Debug build compiles the Rust core — install the NDK and cargo-ndk (docs/ANDROID-BUILD.md)"
  elif [[ "$os" == Linux && ! -e /dev/kvm ]]; then
    not "Android end-to-end: no /dev/kvm, the emulator would be too slow to drive"
  else
    avd="Sonar_QA_API_36"; [[ " $avds " == *" $avd "* ]] || avd="$(awk '{print $1}' <<< "$avds")"
    run "T2  export QA_SERIAL=\"\$(scripts/qa/android-setup.sh --avd $avd$cfg)\""
    if (( slow )); then
      run "T2  QA_SLOW=1 scripts/qa/android-smoke.sh   # every automated QA-NNN, plus QA-142: a share lost offline (~12 min)"
    else
      run "T2  scripts/qa/android-smoke.sh      # every automated QA-NNN; --only QA-NNN for one"
    fi
  fi
fi
if (( ios && xcode && peers )); then
  if ! (( build_core )) || have cargo; then
    run "T2  export QA_UDID=\"\$(scripts/qa/ios-setup.sh$([[ $build_core == 1 ]] && echo ' --build-core')$([[ -f ios/bitchat/GoogleService-Info.plist && $breez_key == 1 ]] || echo ' --allow-missing-config'))\""
    (( share )) && run "T2  scripts/qa/ios-share-smoke.sh   # QA-080…092"
  fi
fi
(( perf && ios && xcode && peers )) && run "T2  scripts/qa/idle-cpu.sh ios \"\$QA_UDID\" 60 --max 3   # QA-050 (android-smoke.sh runs it on Android)"

# Tier 3 — registry sections to walk (the agent drives, the registry says how).
(( messaging )) && WALK+=("Messaging (QA-001…008)" "Reactions (QA-100…106)" "Notifications and lifecycle (QA-020…023)")
(( share )) && WALK+=("Share sheet (QA-080…092)")
(( localtime )) && WALK+=("Private local time (QA-070…077, QA-093)")
(( ui )) && WALK+=("Accessibility (QA-040…043)" "Settings (QA-060)")
(( perf )) && WALK+=("Performance (QA-050…053) — and docs/PERFORMANCE.md when startup changed")
if (( wallet )); then
  WALK+=("Wallet (Cashu) (QA-107…126) — money code: a maintainer reviews it by hand")
  (( ios && xcode )) && ! have cdk-mintd &&
    not "iOS money-moving wallet scenarios (QA-108…124, QA-126): need a local fakewallet cdk-mintd (Wallet intro in docs/QA-SCENARIOS.md); read-only ones (QA-107, QA-109) still run"
  (( android )) && not "Android money-moving wallet scenarios: the Compose build has no mint override — real mint, maintainer-approved amounts only"
  (( breez_key )) || not "Legacy Breez wallet scenarios (QA-123): no Breez key in local config"
fi
(( messaging || core )) && WALK+=("docs/REGRESSIONS.md — the invariants this change must keep, on both platforms")
(( messaging )) && WALK+=("docs/CHAT-TYPES.md — test both chat kinds (pure Marmot and mesh-folded)")
if (( mirror_kt != mirror_swift )); then
  WALK+=("Mirror pair changed on ONE side ($([[ $mirror_kt == 1 ]] && echo SonarAppState.kt || echo SonarAppStore.swift) only): check the other app has the same behaviour, or name the gap in the PR")
fi
(( code && ! messaging && ! share && ! localtime && ! ui && ! perf && ! wallet )) &&
  WALK+=("Messaging QA-001, QA-002 as a sanity pass: every build must still send and receive")

if (( harness )); then
  WALK+=("The QA harness changed: run each changed scripts/qa script once on a platform it serves — e.g. a setup plus \`android-smoke.sh --only QA-001\` — and report it")
fi

echo "RUN (in order):"; for l in "${RUN[@]}"; do echo "  $l"; done
echo; echo "NOT RUN here:"; (( ${#NOT[@]} )) || echo "  (nothing)"
for l in "${NOT[@]+"${NOT[@]}"}"; do echo "  $l"; done
echo; echo "WALK (docs/QA-SCENARIOS.md):"; (( ${#WALK[@]} )) || echo "  (nothing — no app code changed)"
for l in "${WALK[@]+"${WALK[@]}"}"; do echo "  $l"; done
