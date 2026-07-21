# Research Report — Nostr profile override on nsec import

**Branch:** research/nsec-profile-override (worktree: sonar-nsec-profile-research)
**Base:** origin/main @ d79264204 — 2026-07-20
**Question:** if an existing Nostr user imports their nsec into Sonar, is their kind-0 profile "brutally overridden"?

## Verdict

**Confirmed — with nuance.** PR #342 (`b4c1431e0` "Hydrate kind-0 profile after nsec restore") already fixed the *name/nip05* part of the problem, but the **kind-0 event is still fully replaced** by a Sonar-built metadata event that carries only `name`, `display_name`, optional local `about`/`picture` (never passed by any caller), and `nip05` (only the Sonar-claimed handle). Everything else a Nostr user has on their profile — **about/bio, picture/avatar, banner, website, lud16 Lightning address, bot flag, external NIP-05, any custom JSON keys — is destroyed**, silently, automatically, and repeatedly (every relay connect, every rename, every handle claim). No user confirmation anywhere.

## Root cause

`core/sonar-core/src/client.rs:2282` — `publish_profile_background`:

```rust
let mut metadata = Metadata::new().name(name).display_name(name);
if let Some(about) = about.filter(...) { ... }          // local arg only
if let Some(url) = picture.filter(...) { ... }          // local arg only
if let Some(address) = self.claimed_handle... { metadata = metadata.nip05(address); }  // Sonar sidecar only
nostr.set_metadata(&metadata).await                      // full kind-0 REPLACE
```

Kind-0 is a NIP-01 *replaceable* event: `set_metadata` publishes a brand-new event that supersedes whatever the user had. There is **no fetch-and-merge** — the core never reads the existing kind-0 before overwriting it.

Publish triggers (all automatic):
- **Every relay connect** — `MarmotChatView.swift:1062-1078` publishes KeyPackage + profile in lockstep after connect.
- **Rename** — `SonarAppStore.swift:1846 rename()` → `marmot.publishProfile(name:)` (about/picture always nil).
- **Handle claim** — `SonarAppStore.swift:2753` → `publishProfile(name: nickname)`.
- Android parity — `SonarAppState.kt:3175, 3492, 4192` → `SonarCore.publishProfile(nick)`, name-only at all call sites.

## What PR #342 already fixed (credit where due)

`ios/bitchat/Views/Sonar/OwnProfileHydration.swift` (+ Android mirror `OwnProfileHydration.kt`):
- After restore, fetches own kind-0 **before** any republish; remote `name` wins over local nick ("durable kind-0 on relays wins").
- `nip05SafeToPublish`: publish is blocked when the remote nip05 exists and isn't the locally-claimed Sonar handle — so an external NIP-05 is not wiped by accident.
- `canPublishOwnProfile`: no publish while a Sonar-domain pref lacks the core sidecar.
- `clearNicknameForAccountRestore`: persists `""` so a relaunch can't mint `anonXXXX` and republish it over the relay profile.
- Core merges the claimed-handle nip05 into every publish so a nickname-only republish doesn't drop the Sonar handle.

## Remaining override vectors (the gaps)

1. **about/picture/banner/website/lud16/custom keys are never preserved.** `OwnProfileHydrationPlan` carries only `nicknameToAdopt`, `nip05ToAdopt`, `handleLocalToClaim`, `shouldPublishNickname` — no about/picture adoption (zero hits for about/picture/lud16/banner in both iOS and Kotlin plans). The post-hydration "safe" publish uses the adopted remote name but **about/picture = nil** → the relay kind-0 is replaced and bio/avatar/lud16/banner are gone. This fires for the common case: a Nostr user *without* an external nip05 (guard passes, publish proceeds).
2. **External nip05 protection is accidental, not principled.** External nip05 blocks *all* publishes (even legit renames); and once the user claims a Sonar handle, the sidecar nip05 is merged in and the publish **silently replaces the external nip05** with `name@sonarprivacy.xyz`.
3. **Rename wipes everything, every time.** `SonarProfileScreen` edits only the name; `rename()` publishes name-only. Even a Sonar-native user who set a bio/avatar in another client loses it on any Sonar-side edit.
4. **Every-connect republish = repeated, durable destruction** and last-writer-wins flapping with the user's other Nostr clients (they'll republish their profile, Sonar re-overwrites on next connect).
5. **No test coverage for field preservation.** `ios/bitchatTests/OwnProfileHydrationTests.swift` has no assertions mentioning about/picture/lud16 — the destructive path is untested.

## Severity

Silent, automatic, irreversible-from-Sonar's-side destruction of a user's cross-client Nostr identity data on a shared key. Breaks interop expectations (White Noise / Amethyst / Damus users importing the same key lose their profile). Recovery requires the user to notice and republish from another client.

## Recommendations (priority order)

1. **Fetch-and-merge in core** (`publish_profile_background`): before `set_metadata`, fetch current kind-0 (or consume the hydration result), parse the raw JSON content, preserve every field Sonar doesn't manage (about, picture, banner, website, lud16, external nip05, bot, unknown keys), and overwrite only `name`/`display_name` (+ `nip05` when a Sonar handle is claimed).
2. **Never auto-replace an external nip05** with the Sonar handle; make that an explicit opt-in.
3. **Adopt about/picture in `OwnProfileHydrationPlan`** on both platforms into local prefs so later publishes carry them; per the repo's cross-platform rule, any about/avatar editing UI must ship on iOS and Compose together.
4. **Dedupe the every-connect republish**: skip when the hydrated remote kind-0 already matches desired state.
5. **Tests**: assert preservation of about/picture/lud16/banner/external-nip05 across restore → connect → rename → claim, iOS + Android.
6. **UX option**: on nsec import, if a remote kind-0 exists, prompt "Existing Nostr profile found — keep it?" (default: keep).

## Key files

| Path | Role |
|---|---|
| `core/sonar-core/src/client.rs:2282` | `publish_profile_background` — the full-replace publish |
| `ios/bitchat/Views/Sonar/OwnProfileHydration.swift` | post-restore adoption plan (name/nip05 only) |
| `apps/sonar/.../OwnProfileHydration.kt` | Android mirror |
| `ios/bitchat/Views/MarmotChatView.swift:1062-1078, 2114` | every-connect publish + hydration |
| `ios/bitchat/Views/Sonar/SonarAppStore.swift:1846, 1916, 2753` | rename / restore / handle-claim publishes |
| `apps/sonar/.../SonarAppState.kt:3175, 3492, 4192, 3304` | Android publishes + restore |
| `ios/bitchat/ViewModels/ChatViewModel.swift:757-790` | anon-nick minting + restore clearing |
