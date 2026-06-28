# Transponder APNs environments (sandbox vs production)

This explains why Sonar runs **two** transponder instances and how to keep
killed-app iOS chat/call notifications working for **both** Xcode/Debug builds
and TestFlight/App Store builds.

## TL;DR

- APNs has two independent gateways: **sandbox** (`api.sandbox.push.apple.com`)
  and **production** (`api.push.apple.com`).
- A device's push token is **bound to one environment**, decided by the app's
  `aps-environment` entitlement at registration time:
  - installed from **Xcode/Debug** → token valid on **sandbox** only
  - installed from **TestFlight/App Store** → token valid on **production** only
  - the token *bytes* may be identical; what differs is which gateway accepts it.
- Sending a token to the wrong gateway → Apple returns **`BadDeviceToken`** and
  silently drops it. No error reaches the device.
- A single transponder talks to exactly **one** gateway. So Sonar runs two:
  `transponder` (production) and `transponder-sandbox` (sandbox).

## The bug this prevents

Symptom seen in the field: killed-app chat notifications worked on a local
Xcode build but **never arrived on TestFlight**. Root cause: the only deployed
transponder was configured `environment = "sandbox"`. TestFlight devices
register **production** tokens, which the sandbox gateway rejects with
`BadDeviceToken` — so every TestFlight push was discarded. Debug builds
(sandbox tokens) kept working, which masked the problem.

## How the two-instance setup works

Both instances:

- use the **same** server key (`secrets/transponder-server.key`) → **same npub**
- subscribe to the **same** relays

So every MIP-05 notification request (kind-446, gift-wrapped as kind-1059) is
read by **both** instances. Each decrypts the same token and pushes it to **its
own** gateway:

| Build           | Token env  | production instance | sandbox instance |
| --------------- | ---------- | ------------------- | ---------------- |
| TestFlight/App Store | production | **delivers** ✅      | BadDeviceToken (dropped) |
| Xcode/Debug     | sandbox    | BadDeviceToken (dropped) | **delivers** ✅ |

The client needs **no** change: same `TRANSPONDER_NPUB`, same relays. The only
thing that ever needed fixing was having a sender on each gateway.

### FCM lives on one instance only

FCM (Android + the wallet wakeup bridge) is environment-agnostic — Firebase
handles APNs bridging itself. If both instances had FCM enabled, every Android
push would be sent **twice**. So FCM is enabled on the **production** instance
only (`production.toml`) and disabled on `sandbox.toml`. Production owning FCM
means Android keeps working even if the sandbox instance is turned off.

## Repo layout (canonical)

- `transponder/config/production.toml` — production APNs gateway + FCM enabled
- `transponder/config/sandbox.toml`    — sandbox APNs gateway + FCM disabled
- `compose.yml` services: `transponder` (production), `transponder-sandbox`
  (sandbox), `breez-nds`

Bring up: `docker compose up -d`

## Current live state (65.108.246.14, sonar-push)

The fix was first applied hot on the box, so the running layout uses historical
filenames that differ from the repo's canonical names above. As of this writing:

| Container                  | Config on box                  | Gateway    | FCM |
| -------------------------- | ------------------------------ | ---------- | --- |
| `sonar-transponder`        | `config/production.toml`*      | sandbox    | on  |
| `sonar-transponder-prod`   | `config/apns-production.toml`  | production | off |

\* On the live box this file currently contains `environment = "sandbox"` — the
name is historical, not its contents. The production sender is the separately
added `sonar-transponder-prod`. Both run the locally-built `transponder:local`
image rather than the pinned ghcr image in the repo compose.

**Both work today.** To converge the box onto the repo's canonical layout on the
next maintenance window:

```sh
cd ~/sonar-push
# rename to canonical files
mv transponder/config/production.toml      transponder/config/sandbox.toml      # (set environment="sandbox", fcm disabled)
mv transponder/config/apns-production.toml transponder/config/production.toml    # (environment="production", fcm enabled)
# replace the two services with the repo's `transponder` + `transponder-sandbox`
# then:
docker compose up -d
docker rm -f sonar-transponder-prod    # remove the old ad-hoc container name
```

(Optional — only do this when you can tolerate a brief dev-push gap. The
production path is unaffected by the rename.)

## Verifying

Check each instance booted on the right gateway:

```sh
docker logs sonar-transponder      2>&1 | grep "APNs push service configured"
docker logs sonar-transponder-prod 2>&1 | grep "APNs push service configured"
# expect environment":"sandbox"  and  environment":"production" respectively
```

End-to-end: kill the app on a TestFlight device, have a peer send a message,
and confirm the notification arrives.

### Gotcha: the transponder does not log APNs send results

It logs `"FCM notification accepted"` for FCM, but emits **no** per-send line for
APNs success **or** failure. So a wrong-gateway `BadDeviceToken` is invisible in
the logs — the only reliable APNs signal is the notification actually arriving on
the device. When debugging, the last APNs-path log line you'll see is
`"Processed notification event","notifications_admitted":1`.

## Known issue

`wss://nostr.relay.hedwig.sh` currently fails TLS at connect
(`received fatal alert: InternalError`) for both instances; only
`relay.damus.io` and `nos.lol` carry traffic. Pushes still flow via the working
relays, but this relay should be fixed separately.
