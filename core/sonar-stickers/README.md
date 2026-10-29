# sonar-stickers

Sticker packs on Nostr, as Sonar publishes and installs them: the pack model,
its validation, and conversion to and from Nostr events. The crate moves no
bytes itself: it does not upload blobs, query relays or send chat messages.

* A pack is an addressable event of kind `30031` (`STICKER_PACK_KIND`), format
  `sonar-sticker-pack-v1`. Each sticker names its image by SHA-256 and a
  Blossom HTTPS URL.
* The packs a user installed are a replaceable kind `10031` list
  (`USER_STICKER_PACKS_KIND`).
* A sticker sent in a chat is a reference tag naming its pack, its shortcode
  and the SHA-256 of its image.

The events reuse the shape of NIP-51 / NIP-30 custom-emoji sets, one kind
above them (`30030` / `10030`). On the emoji kinds, every Nostr client would
read a sticker pack as an emoji set and the installed list as the user's emoji
list. Neither kind is in the Nostr kind registry yet.

## Features

| Feature | Default | What it adds |
|---|---|---|
| `nostr` | yes | Build and parse pack, installed-list and reference events with [`nostr`](https://crates.io/crates/nostr). |
| `signal-import` | no | Import a Signal sticker pack from its share link: fetch it, then decrypt the manifest and every sticker. |
| `wasm` | no | Placeholder for browser bindings; empty for now. |

The wire format is described in
[`docs/SONAR-STICKERS.md`](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-STICKERS.md).

```sh
cargo test -p sonar-stickers --all-features
```
