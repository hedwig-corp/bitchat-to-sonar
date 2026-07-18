# Transcript Engine — Integration

## App supplies

- Stable message ids + equality for diff / continuity
- Row content (`@Composable` bubble or UIKit cell configure)
- Preferred size / media reserved-height fingerprint inputs (app-specific)
- Composer height or keyboard layout guide binding
- Bounded local message page from your database

## Library owns

- Declarative open: `LiveEdge | UnreadDivider | Jump(id)`
- Inset follow: capture `wasAtTail` → pin | lockstep | ignore (10 ms coalesce)
- Compose host: full-height list + overlaid composer + owned bottom padding
- Day section grouping helpers (SPM) and sticky-day keys
- Pre-measured row height cache (SPM)

## Kotlin (Compose)

```kotlin
// settings.gradle.kts
include(":transcript-engine-policy", ":transcript-engine-compose")
project(":transcript-engine-policy").projectDir = file("../../packages/transcript-engine-policy")
project(":transcript-engine-compose").projectDir = file("../../packages/transcript-engine-compose")

// composeApp/build.gradle.kts
commonMain.dependencies {
    api(project(":transcript-engine-compose"))
    api(project(":transcript-engine-policy"))
}
```

Use `TranscriptHostScaffold` + `TranscriptScrollPolicy.resolveOpenAction(...)`.

Golden contract: `packages/transcript-engine-policy/golden/open-action.json`.

## Swift (UIKit / SwiftUI)

Add local package `ios/localPackages/TranscriptEngine` to Xcode.

```swift
import TranscriptEngine

let action = TranscriptScrollPolicy.openAction(
    unreadAnchorId: anchorId,
    unreadCountAtOpen: unreadCount,
    unreadAnchorAbandoned: abandoned
)
```

Sonar keeps `SN*` names via `ios/bitchat/Views/Sonar/TranscriptEngineSonarCompat.swift` (app-side shims; not part of the public library API).

## Sonar wiring (this repo)

- Compose: thin shims in `apps/sonar/.../TranscriptScrollPolicy.kt` (`transcriptDecisionToLegacyPin`) and `TranscriptPolicyHostScaffold.kt` (kill switches + demo)
- iOS: `SNTranscriptCollectionHost.swift` imports `TranscriptEngine`; policy/day types deleted from Sonar target

## Non-goals

No Marmot/Nostr/crypto/send pipeline in the public API.
