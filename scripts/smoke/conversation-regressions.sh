#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLATFORM="${1:-all}"

run_compose() {
  "$ROOT/apps/sonar/gradlew" \
    -p "$ROOT/apps/sonar" \
    :composeApp:jvmTest \
    --tests 'chat.bitchat.sonar.ConversationRegressionSmokeTest'
}

run_apple() {
  local destination="${SONAR_IOS_DESTINATION:-}"
  if [[ -z "$destination" ]]; then
    local simulator_id
    simulator_id="$(xcrun simctl list devices available \
      | sed -nE 's/^[[:space:]]+iPhone[^()]*(\(([0-9A-F-]+)\)).*/\2/p' \
      | head -1)"
    if [[ -z "$simulator_id" ]]; then
      echo "no available iPhone simulator; set SONAR_IOS_DESTINATION" >&2
      exit 1
    fi
    destination="platform=iOS Simulator,id=$simulator_id"
  fi
  xcodebuild \
    -quiet \
    -project "$ROOT/ios/bitchat.xcodeproj" \
    -scheme 'bitchat (iOS)' \
    -destination "$destination" \
    -only-testing:bitchatTests_iOS/SonarConversationRegressionSmokeTests \
    test
}

case "$PLATFORM" in
  all)
    run_compose
    run_apple
    ;;
  android|compose)
    run_compose
    ;;
  ios|apple)
    run_apple
    ;;
  *)
    echo "usage: $0 [all|android|ios]" >&2
    exit 2
    ;;
esac
