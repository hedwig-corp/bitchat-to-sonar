# Transcript Engine

Signal-shaped transcript list engine extracted from Sonar as reusable library modules.

**Sonar is the first consumer.** The libraries own open / scroll / inset policy and Compose host scaffolding; apps supply message identity, row content, composer height, and bounded DB paging.

## Modules

| Module | Platform | Role |
|---|---|---|
| `packages/transcript-engine-policy/` | KMP (JVM + Android) | Pure policy: `TranscriptOpenAction`, pin / lockstep / ignore, continuity, coalesce |
| `packages/transcript-engine-compose/` | KMP Compose | `TranscriptHostScaffold`, scroll effects, tail anchor helpers |
| `ios/localPackages/TranscriptEngine/` | SPM (iOS + macOS) | Mirrored policy + day sections + row height cache (generic `Transcript*` API) |

UIKit collection host (`SNTranscriptCollectionHost`) remains in Sonar for now — it is coupled to `SNMessage` rendering. Tracked gap: extract a generic UIKit host in a follow-up.

## Samples

- `samples/compose/SampleTranscript.kt` — fake-message Compose host
- `samples/uikit/SampleTranscriptHost.swift` — string-row UIKit sketch

See [INTEGRATION.md](INTEGRATION.md) for app wiring.
