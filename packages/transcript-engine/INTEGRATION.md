# Transcript Engine — Integration

## App supplies

- Stable message ids + equality for diff / continuity
- Row content (`@Composable` bubble or UIKit `configureCell` closure)
- Preferred size / media reserved-height fingerprint inputs (app-specific `heightKey`)
- Composer height or keyboard layout guide binding
- Bounded local message page from your database

## Library owns

- Declarative open: `LiveEdge | UnreadDivider | Jump(id)`
- Inset follow: capture `wasAtTail` → pin | lockstep | ignore (10 ms coalesce)
- **Viewport-space owned bottom inset** (`transcriptOwnedBottomContentInset`) — never convert composer frames into scroll-view content space (R-009)
- Compose host: full-height list + overlaid composer + owned bottom padding
- UIKit host: `TranscriptCollectionHostView` — collection VC + keyboardLayoutGuide composer + policy wiring
- Day section grouping helpers (SPM) and sticky-day headers
- Pre-measured row height cache (SPM)

## Kotlin (Compose)

```kotlin
// settings.gradle.kts
include(":transcript-engine-policy", ":transcript-engine-compose", ":transcript-engine-sample")
project(":transcript-engine-policy").projectDir = file("../../packages/transcript-engine-policy")
project(":transcript-engine-compose").projectDir = file("../../packages/transcript-engine-compose")
project(":transcript-engine-sample").projectDir = file("../../packages/transcript-engine-sample")

// composeApp/build.gradle.kts
commonMain.dependencies {
    api(project(":transcript-engine-compose"))
    api(project(":transcript-engine-policy"))
}
```

Use `TranscriptHostScaffold` + `TranscriptScrollPolicy.resolveOpenAction(...)`.

Sample: `SampleTranscriptApp` in `:transcript-engine-sample`.

Golden contract: `packages/transcript-engine-policy/golden/open-action.json` (asserted in `:transcript-engine-policy:check` and SPM tests).

## Swift (UIKit / SwiftUI)

Add local package `ios/localPackages/TranscriptEngine` to Xcode.

```swift
import TranscriptEngine

TranscriptCollectionHostView(
    entries: messages.map { TranscriptHostEntry(id: $0.id, date: $0.date) },
    heightKey: { row in "m|\(row)" },
    callbacks: TranscriptCollectionHostCallbacks(
        configureCell: { _, cell, _, item in /* dequeue + configure */ },
        itemHeight: { item, key, width in 44 },
        headerHeight: { _, width in 28 }
    ),
    composer: { MyComposerView() }
)
.ignoresSafeArea(.keyboard, edges: .bottom)
```

SPM example: `SampleChatDemo.makeViewController(messages:)`.

Sonar keeps `SN*` names via `TranscriptEngineSonarCompat.swift`; production iOS path uses `SNTranscriptCollectionHost` → `TranscriptCollectionHostView` through `SNTranscriptCollectionHostAdapter.swift`.

## Sonar wiring (this repo)

- Compose: thin shims in `apps/sonar/.../TranscriptScrollPolicy.kt` and `TranscriptPolicyHostScaffold.kt` (kill switches + demo)
- iOS: `SNTranscriptCollectionHost.swift` + adapter; inset math in `TranscriptEngine` (`transcriptOwnedBottomContentInset`)

## Non-goals

No Marmot/Nostr/crypto/send pipeline in the public API. No AppKit Mac collection host in v1.
