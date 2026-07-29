# External signer (Amber / NIP-55)

Sonar on Android can keep the account secret key **outside the app process**,
in a [NIP-55](https://github.com/nostr-protocol/nips/blob/master/55.md) signer
app such as [Amber](https://github.com/greenart7c3/Amber). The app then never
holds the nsec: every signature and NIP-44 operation is delegated to the
signer, which enforces per-app, per-kind permissions.

## Architecture

```
Rust core (sonar-core)                sonar-ffi                Kotlin (androidMain)
──────────────────────                ─────────                ────────────────────
Identity ── signer() ──► NostrSigner ─► RemoteSignerAdapter ─► ForeignNostrSigner
   │                                    (verify sig/author/id)   = AmberSignerClient
   │                                                              │
   ├─ kdf_root() ─► geohash / iroh-call derivations               ├─ ContentResolver (background)
   └─ local_keys() ─► Err(NeedsLocalKey) on remote accounts       └─ Intent + ActivityResult (foreground)
```

- `sonar_core::identity::Identity` is either **local** (holds `Keys`, exactly
  the previous behavior — all derivations byte-identical) or **remote**
  (public key + `Arc<dyn NostrSigner>`). Everything that signs or NIP-44s goes
  through `Identity::signer()`; `nostr_sdk::Client` receives the signer, which
  also covers NIP-42 relay AUTH automatically.
- The MLS/Marmot layer (MDK) never touches the Nostr secret — kind-445 group
  messages and outer kind-1059 wraps are signed by ephemeral/MLS keys. Only
  the KeyPackage envelope (30443), gift-wrap seals (13) and account-level
  unwraps need the signer.
- `RemoteSignerAdapter` (sonar-ffi) treats everything returned by the host as
  untrusted: it verifies the schnorr signature, the author, and that the
  returned event id matches the requested unsigned event. Foreign calls run
  on `spawn_blocking`, so a pending approval screen never stalls a runtime
  worker.
- `AmberSignerClient` (Kotlin) tries the signer's ContentProvider first
  (background-capable — push wakes and killed-app drains keep working once
  the user granted "remember" permissions at login) and falls back to the
  intent flow through the foreground Activity with id-correlated,
  batch-capable responses.

## What still needs raw secret bytes

NIP-55 has no "export raw key bytes" primitive (by design), so KDF-based
features re-root on ONE device-local random root for signer accounts:

| Feature | Local account | Signer account |
| --- | --- | --- |
| Geohash ephemeral ids, iroh call identity, Lightning wallet seed | derived from nsec bytes (unchanged, cross-platform) | derived from the device-local random `signer.kdfRoot` (domain-separated KDFs) — **not restorable from the account key** |
| Blossom account backup / nsec restore | available | **unavailable** (wrapping key derives from the nsec); settings rows hidden AND the FFI rejects with a typed `NeedsLocalKey` error |
| nsec export | available | n/a — nothing to export |

`signer.kdfRoot` is minted exactly once, under the identity lock, during
adopt. There is deliberately no background self-heal mint: it would silently
fork the wallet seed (a fresh empty Breez node while funds sit on the old
one). A post-onboarding account with a missing root fails identity load
loudly instead.

The permission batch requested at login mirrors the core-owned list
`sonar_core::signer_kinds::IDENTITY_SIGNED_KINDS` (22242, 24242, 0, 13,
30078, 10063, 10031, 30443, 23353 + nip44 encrypt/decrypt). The Kotlin mirror
in `commonMain/.../signer/Nip55.kt` is pinned against the core list across
the real FFI by `Nip55KindsFfiParityTest` (jvmTest); add new identity-signed
kinds to the CORE list first.

## Failure semantics (retry policy)

The signer bridge returns a tri-state result (`Ok` / `Rejected` /
`Unavailable`). `Rejected` (the user said no) is permanent; `Unavailable`
(backgrounded with no remembered grant, approval timeout, signer busy) is
transient and — critically — a transient failure while unwrapping a gift wrap
surfaces as a retryable error, so undelivered welcomes/DMs stay in the sync
window instead of being durably dropped. The relay drain also unwraps each
gift wrap exactly once (each unwrap is two cross-process IPC calls on a
signer account). The intent-approval path is guarded by a circuit breaker
(3 consecutive rejections/timeouts → closed for 2 minutes) so a peer cannot
drive an approval storm from an ordinary drain.

Adoption is verified: `SonarIdentity.verifySigner()` demands one valid
signature for the claimed pubkey before the binding is persisted, because the
NIP-55 login intent is implicit and any installed app could answer it with an
arbitrary npub.

## Storage / mode invariant

`AndroidSecrets` holds either `"nsec"` (local) or `"signer.pubkey"` +
`"signer.package"` + `"signer.kdfRoot"` (signer account) — never both, with
`"signer.pendingLogin"` marking a binding whose onboarding never completed
(not yet an account). `importIdentity` (nsec restore) clears the signer
binding; `adoptExternalSigner` refuses to run over an existing local key;
wipe clears everything. All writes are durable-commit, update-in-place
(Account Key Durability rule). All mode questions go through one
`storedAccount()` reader in `SonarCore.android.kt`.

## Platform gaps (tracked)

- **iOS/macOS**: NIP-55 is Android-only (intents/ContentResolver). The Apple
  path to the same goal is NIP-46 (bunker) remote signing — not implemented;
  the Apple app keeps using local keys.
- **Desktop (Compose jvm)**: same — `ExternalSigner.isAvailable()` is false;
  NIP-46 is the follow-up there too.
- **Offline receive with a killed app**: background operations that need the
  signer (relay AUTH, gift-wrap unwrap) work only through Amber's
  ContentProvider grants; if the user revokes them, background sync degrades
  until the app is foregrounded.
