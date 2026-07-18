# Transcript Engine

Signal-shaped transcript list engine extracted from Sonar as reusable library modules.

**Shipped surfaces in v1: Compose (KMP) + iOS UIKit.** Sonar is the first production consumer. The libraries own open / scroll / inset policy, Compose host scaffolding, and a generic UIKit collection host; apps supply message identity, row content, composer chrome, and bounded DB paging. AppKit / Mac Catalyst collection-host parity is an explicit tracked gap — macOS Sonar still uses the SwiftUI overlay host documented in `docs/SIGNAL-TRANSCRIPT-PATTERNS.md`.

## Modules

| Module | Platform | Role |
|---|---|---|
| `packages/transcript-engine-policy/` | KMP (JVM + Android) | Pure policy: `TranscriptOpenAction`, pin / lockstep / ignore, continuity, coalesce |
| `packages/transcript-engine-compose/` | KMP Compose | `TranscriptHostScaffold`, scroll effects, tail anchor helpers |
| `packages/transcript-engine-sample/` | KMP Compose | Buildable fake-message sample (`SampleTranscriptApp`) |
| `ios/localPackages/TranscriptEngine/` | SPM (iOS + macOS policy; **UIKit host is iOS-only**) | Policy + day sections + row height cache + generic `TranscriptCollectionHostView` |

Sonar iOS wraps the UIKit host via `SNTranscriptCollectionHostAdapter.swift` (bubble cells + media measure pass stay in the Sonar target). Kill switch `SONAR_TRANSCRIPT_COLLECTION_HOST` remains Sonar-owned.

## Samples

- `:transcript-engine-sample` — `SampleTranscriptApp` (CI: `compileKotlinJvm`)
- SPM `SampleChat` target — string rows via `TranscriptCollectionHostView` (`Examples/SampleChat/`)
- Legacy sketches under `samples/` (reference only; prefer the modules above)

Shared open-action contract: `packages/transcript-engine-policy/golden/open-action.json` (loaded by KMP + SPM tests).

See [INTEGRATION.md](INTEGRATION.md) for app wiring.
