Vendored `nostr-blossom` 0.44.0 with one patch in `src/client.rs`:

- `upload_blob` treats `201 Created` as success (nostr.download returns 201; upstream only accepts 200).

Remove this vendor tree when `nostr-blossom` on crates.io includes the same fix.
