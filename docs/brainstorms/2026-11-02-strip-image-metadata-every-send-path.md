# Strip image metadata on every send path

Source: [calle](https://x.com/callebtc/status/2116944944392814764) — "Signal strips
away image metadata when you send a photo"; [JeffG](https://x.com/erskingardner/status/2117243162154430790)
— "so does @whitenoisechat". The goal is to make the same claim for Sonar and have
it hold for every way an image can leave the device.

## What already exists (2026-11-02, `main` @ fdf091cbb)

| Entry point | Transport | Metadata today |
|---|---|---|
| Photo picker, iOS | Marmot | Re-encoded with `UIImage.jpegData` (`SonarAppStore.swift:1788`), then MDK strips JPEG again. Clean. |
| Photo picker, iOS | BLE mesh | `ImageUtils.processImage` via `ChatViewModel.sendImage` (`SonarAppStore.swift:8968`). Clean. |
| Photo picker, macOS | any | `reencodeToJpeg` is `#else return data` (`SonarAppStore.swift:1792`): raw bytes. MDK strips them on Marmot only if they are JPEG/PNG. |
| Photo picker, Compose | any | `reencodeToJpeg` (`MediaUI.android.kt:591`, `MediaUI.jvm.kt:301`). Clean, but `BitmapFactory` ignores EXIF orientation, so a sideways photo is possible (unverified). |
| GIF from picker | any | Passed through untouched by the apps and by MDK. |
| iOS share sheet (`SonarShareIntake.swift:314`), macOS drop (`SonarMacRootView.swift:1251`), iOS Send file (`SonarDMScreen.swift:787`) | BLE mesh | `sendAttachment` → `chatViewModel.sendFile`: **byte-exact, all EXIF/GPS sent**. |
| Same | Marmot | `sendAttachment` → MDK. MDK strips only `image/jpeg` and `image/png`; HEIC, WebP, TIFF and AVIF pass through, and a failed strip **falls back to the original bytes** (`mdk-core/src/encrypted_media/metadata.rs` @ `e8cd584`). |
| Compose share intent / desktop drop / Send file (`SonarAppState.kt:9237`) | both | Same as above: byte-exact on mesh, MDK-only on Marmot. |
| Video | both | Already location-stripped and fail-closed (#615, QA-012). Out of scope. |

There is no avatar or other public image upload, so every image in scope is
E2E-encrypted. Peers still see the metadata.

## Clarified Problem Statement

**Goal:** No image leaves Sonar carrying EXIF, GPS, XMP, IPTC or maker metadata,
whatever the entry point (picker, share sheet, drag-drop, Send file) and transport
(BLE mesh, White Noise/Marmot), on iOS, macOS, Android and desktop.

**Decisions (from the user, 2026-11-02):**
- Scope: **every image, including Send file**. This deliberately goes further than
  Signal, whose document path is byte-exact. Record the deviation in the PR.
- Format: **strip in place** where possible. Pixels stay untouched, so HEIC stays
  HEIC and PNG stays PNG.
- Unverifiable or unrewritable image: **re-encode to JPEG**. Refuse only when it
  cannot be decoded at all.

**Constraints:**
- Cross-Platform Feature Rule: `ios/` and `apps/sonar/` ship together.
- Orientation must survive. In-place JPEG/HEIC stripping keeps a minimal Orientation
  tag or bakes it into the pixels, and the re-encode fallback applies orientation
  before encoding.
- Performance: sanitizing runs off the main thread at send confirmation (Signal's
  lazy finalization), is O(bytes) per item, and never gates the local echo or
  chat open. It adds no fan-out.
- Fail closed on doubt, matching the video rule: never "couldn't parse → send as-is".
- Identify images by sniffing the bytes, not by the declared MIME. A `.jpg` named
  `notes.bin` must still be stripped.

**Non-goals:**
- Video (done in #615) and audio or voice-note metadata.
- Document metadata (PDF/Office author fields). Signal does not strip these either.
- Receive-side stripping of images from stock White Noise or bitchat peers.
- Changing MDK itself. That is a follow-up (see Open questions).

**Success criteria:**
- Fixtures with GPS + EXIF + XMP + IPTC (JPEG, HEIC, PNG with `eXIf`/`iTXt`, WebP
  with EXIF/XMP chunks, GIF with XMP app extension) sent through each entry point ×
  transport arrive with none of those fields, checked with `sonar-cli fetch` plus
  `exiftool`, or a Rust/Kotlin parser in tests.
- In-place results decode to identical pixels (decoded-pixel hash equal) and
  display upright.
- An unparseable image arrives as a clean JPEG, and an undecodable one is refused
  with a toast.
- Guarding tests on both platforms, a new `QA-NNN` scenario in
  `docs/QA-SCENARIOS.md`, and a scripted step in `scripts/qa/android-smoke.sh`
  where it can be driven headlessly.
- Cold-start and send benchmarks unchanged (sanitizing is off the critical path).

## Approaches Considered

### Approach A: One Rust sanitizer, called at each app's transport boundary
- Sketch: add a pure function `sanitize_image(bytes) -> Clean{bytes, stripped} | NeedsReencode | NotImage`
  in a small core crate (or `sonar-core` module), exposed over UniFFI. It rewrites
  containers in place: JPEG drops APP1 Exif/XMP, APP13 and COM and writes back a
  minimal Orientation-only APP1; PNG drops `eXIf`, `tEXt`, `iTXt` and `zTXt`; WebP
  drops the EXIF/XMP chunks and fixes the VP8X flags; GIF drops comment and
  non-NETSCAPE application extensions; HEIC/AVIF zero-fill the Exif and `mime`/XMP
  item payloads without moving bytes, the same trick as `VideoPrivacy.kt`. Each app
  calls it at its single send boundary (Compose `sendMediaAttachment`; iOS
  `sendImage`/`sendAttachment` and the Swift mesh `sendFile`). On `NeedsReencode`
  the platform re-encodes to JPEG with orientation applied: ImageIO on iOS/macOS,
  `ImageDecoder` on Android (decodes HEIC on API 28+), ImageIO on JVM.
- Affected files: new `core/<crate>/`, `core/sonar-ffi`, `SonarAppState.kt`
  (`sendMediaAttachment`, finalize at ~8878), `MediaUI.android.kt`/`MediaUI.jvm.kt`
  (orientation-aware fallback), `SonarAppStore.swift` (`sendImage`, `sendAttachment`,
  macOS `reencodeToJpeg`), byte-exact vectors under `core/<crate>/vectors/`.
- Tradeoffs: one parser, pinned by vectors, that both apps consume, as the
  bitchat-protocol crate does for the wire format. Every entry point is covered by
  construction, which follows "gate at the boundary, not the entry". It costs a
  UniFFI ABI change and a hand-written HEIF item parser, the riskiest piece. Fuzz
  the crate, because it parses attacker-controlled bytes on the sender's own files.
- Effort: L

### Approach B: Per-platform sanitizers, following the video precedent
- Sketch: mirror #615. iOS/macOS uses ImageIO
  `CGImageDestinationCopyImageSource` with metadata removal (`kCGImageMetadataShouldExcludeGPS`,
  nil EXIF/TIFF/IPTC dictionaries, Orientation kept), which is a lossless container
  rewrite for JPEG, HEIC, PNG and TIFF. Compose adds a pure-Kotlin `commonMain`
  `ImagePrivacy.kt` next to `VideoPrivacy.kt` for JPEG, PNG, WebP and GIF, and
  routes HEIC to the JPEG re-encode. Both are called at the same send boundaries
  as A.
- Affected files: new `ImagePrivacy.kt` + `ImagePrivacyTest`/fixture test;
  `SonarAppState.kt`; `MediaUI.android.kt`/`.jvm.kt`; `SonarAppStore.swift`; new
  `ImageMetadataStripTests.swift`; `ImageUtils.swift` (reuse).
- Tradeoffs: fastest to ship, and it reuses OS-hardened parsers on Apple platforms
  plus a pattern reviewers already accepted. It is two implementations that can
  drift, the "same logic written twice" risk in `docs/REGRESSIONS.md`. HEIC on
  Android always becomes JPEG (quality loss, not a privacy loss).
- Effort: M

### Approach C: Fix it in MDK, add a mesh-only app strip
- Sketch: upstream MDK changes: fail closed when the strip fails, sanitize
  WebP/HEIC/GIF, and sniff the bytes instead of trusting the declared MIME. The
  Marmot path is then clean for every client, White Noise included. The apps add
  a strip only on the BLE mesh path, which never touches MDK.
- Affected files: `marmot-protocol/mdk` `encrypted_media/metadata.rs`;
  `core/Cargo.lock` rev bump; the mesh send paths in both apps.
- Tradeoffs: helps the whole Marmot ecosystem and makes Jeff's claim stronger. It
  depends on upstream review and an MDK bump, which requires a `sonar-sim
  group-scale` rerun under the Performance Analysis Rule. It still needs an app
  sanitizer for mesh, so it does not avoid A or B, it only shrinks them.
- Effort: M (plus an upstream wait)

## Recommendation

**Approach A.** "Every image, every path, both platforms" is the kind of invariant
this repo already moves into one crate with vectors (`bitchat-protocol`). A single
sanitizer called at the send boundary is the only design where a new entry point
cannot silently skip it. Start with JPEG, PNG and the re-encode fallback, which
cover most real photos; HEIC in-place and WebP/GIF can land in a second PR, and
until then they go through the JPEG fallback (clean, not lossless). Open the MDK
fail-closed issue (C) in parallel as a follow-up: it is defense in depth, not the
fix. If time to ship matters more than the single implementation, B is the
fallback, and its tests carry over to A unchanged.

## Open questions

- Does the iOS Photos share sheet hand Sonar HEIC or a JPEG conversion, and does
  "Location: off" in the share options already remove GPS? This decides how often
  the HEIC path matters.
- Android orientation: does today's `reencodeToJpeg` send portrait photos sideways?
  Check on a device before the change, because if it does, the fallback fix is also
  a bug fix.
- Should the UI say "Location removed" anywhere (Signal shows nothing), and should
  Send file get a future "send original" opt-out, now that it strips too?
- What do stock bitchat clients do with the mesh file (`0x05` TLV) after the
  bytes change? Stripping keeps the file valid, so this should be a no-op. Confirm
  with the cross-replay harness.
- MDK `e8cd584` fails open (`"using original data"`) on a strip failure. File it
  upstream with a repro either way.
