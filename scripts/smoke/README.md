# Conversation regression smoke suite

This fast suite covers the chat-list failures seen during device testing:

- a Sara message routing into a Vincenzo/Vincenzo-Mac conversation;
- rotating BLE aliases creating duplicate rows;
- duplicate direct Marmot groups;
- cold-start hydration changing the initial order;
- a new message moving only its own conversation to the top.

Run both app implementations:

```sh
scripts/smoke/conversation-regressions.sh
```

Run one implementation:

```sh
scripts/smoke/conversation-regressions.sh android
scripts/smoke/conversation-regressions.sh ios
```

The iOS run automatically chooses an available iPhone simulator. Override it
for a specific simulator or an attached device:

```sh
SONAR_IOS_DESTINATION='platform=iOS,id=<device-udid>' \
  scripts/smoke/conversation-regressions.sh ios
```
