# Notification sound

Shared PCM sources live in `raw/` for Apple and Compose Desktop:

- `sonar_notification.wav` for relay, Internet, and push notifications.
- `sonar_ble_notification.wav` for notifications received over Bluetooth.

Both are mono, 44.1 kHz, 16-bit PCM conversions of user-supplied source audio
without LIST/INFO metadata chunks (Android's NotificationPlayer often fails
silently on WAV metadata chunks).

They are mixed for chat-alert loudness comparable to Signal/Telegram: soft
compression plus a −1.0 dBTP limiter, targeting roughly −12 LUFS integrated
with peak near −1 dBFS. Quiet source renders play back softer than the system
default even when the ringer is maxed, so do not ship peak-normalized-only
re-encodes of soft masters.

Android packages MP3 copies of the same assets under
`apps/sonar/composeApp/src/androidMain/res/raw/` — regenerate them after editing
the WAVs, then bump the Android notification channel IDs in
`Notifier.android.kt` so existing installs recreate channels against the new
files:

```sh
ffmpeg -y -i assets/notifications/raw/sonar_notification.wav \
  -codec:a libmp3lame -qscale:a 3 \
  apps/sonar/composeApp/src/androidMain/res/raw/sonar_notification.mp3
ffmpeg -y -i assets/notifications/raw/sonar_ble_notification.wav \
  -codec:a libmp3lame -qscale:a 3 \
  apps/sonar/composeApp/src/androidMain/res/raw/sonar_ble_notification.mp3
```
