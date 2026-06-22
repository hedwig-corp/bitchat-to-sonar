#!/bin/bash
#
# Send a test Marmot message to trigger the push notification pipeline.
#
# Usage:
#   scripts/test-push.sh <recipient-npub>
#
# Prerequisites:
#   1. The recipient's Sonar app is installed and has registered its push
#      token with the transponder (check device logs for "MIP-05 push token
#      registered").
#   2. The transponder is running at push.sonar.hedwig.sh.
#   3. `cargo build -p sonar-cli` has been run.
#
# What happens:
#   1. Creates a throwaway agent identity in /tmp/sonar-push-test/
#   2. Publishes its KeyPackage to relays
#   3. Sends an encrypted Marmot message to the recipient
#   4. The transponder detects the new message on the relay and sends an
#      APNS/FCM push to the registered device
#   5. The device wakes up, syncs, and shows a local notification
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../core" && pwd)"

RECIPIENT="${1:-}"
MESSAGE="${2:-Push test from $(date '+%H:%M:%S')}"

if [ -z "$RECIPIENT" ]; then
    echo "Usage: $0 <recipient-npub-or-hex> [message]"
    echo ""
    echo "Example:"
    echo "  $0 npub1abc...xyz"
    echo "  $0 npub1abc...xyz 'Hello from the push test script!'"
    exit 1
fi

TEST_HOME="/tmp/sonar-push-test"

echo "==> Building sonar-cli..."
(cd "$CORE_DIR" && cargo build -p sonar-cli --quiet 2>&1)

CLI="$CORE_DIR/target/debug/sonar-cli"

if [ ! -f "$TEST_HOME/config.json" ]; then
    echo "==> Creating throwaway test identity..."
    "$CLI" --home "$TEST_HOME" init --force
fi

echo "==> Test identity:"
"$CLI" --home "$TEST_HOME" identity

echo ""
echo "==> Publishing KeyPackage to relays..."
"$CLI" --home "$TEST_HOME" publish

echo ""
echo "==> Sending test message to $RECIPIENT..."
echo "    Message: $MESSAGE"
"$CLI" --home "$TEST_HOME" send --to "$RECIPIENT" --text "$MESSAGE"

echo ""
echo "==> Done. If the recipient's app is registered with the transponder,"
echo "    a push notification should arrive within ~10 seconds."
echo ""
echo "    Check the device for:"
echo "      - 'New Sonar message' notification"
echo "      - Or open the app and look for the new conversation"
