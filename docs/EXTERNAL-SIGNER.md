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
features re-root on device-local random material for signer accounts:

| Feature | Local account | Signer account |
| --- | --- | --- |
| Geohash ephemeral ids, iroh call identity | derived from nsec bytes (unchanged) | derived from a device-local random `signer.kdfRoot` |
| Lightning wallet seed | derived from nsec (unchanged, cross-platform) | device-local random `wallet.entropyHex` — **not restorable from the account key** |
| Blossom account backup / nsec restore | available | **unavailable** (wrapping key derives from the nsec); settings rows hidden |
| nsec export | available | n/a — nothing to export |

The permission batch requested at login lives in
`commonMain/.../signer/Nip55.kt` (`SIGN_EVENT_KINDS`): 22242, 24242, 0, 13,
30078, 10063, 10031, 30443, 23353 + nip44 encrypt/decrypt. If a new
identity-signed kind is added to the core, add it there too or signer users
get a surprise approval screen (guarded by `Nip55Test`).

## Storage / mode invariant

`AndroidSecrets` holds either `"nsec"` (local) or `"signer.pubkey"` +
`"signer.package"` + `"signer.kdfRoot"` + `"wallet.entropyHex"` (signer
account) — never both. `importIdentity` (nsec restore) clears the signer
binding; `adoptExternalSigner` refuses to run over an existing local key;
wipe clears everything. All writes are durable-commit, update-in-place
(Account Key Durability rule).

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
