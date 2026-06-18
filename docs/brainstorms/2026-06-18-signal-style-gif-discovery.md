# Signal-style GIF discovery and Sonar Nostr catalogs

Date: 2026-06-18. Status: chosen architecture, first production slice.

## Goal

Reproduce the useful parts of Signal Android's GIF experience in Sonar without
hard-coding Sonar to a single third-party provider. Users should be able to
discover GIFs, save them into their Sonar app, and send them through Sonar's
existing encrypted media path.

## Signal Android reference

Signal Android's current `main` at
`5929866ae02f8443d128c9a45a31ad32afa9b69d` implements GIFs as a media-keyboard
surface, not as a file picker:

- `GifKeyboardPageFragment` embeds a GIF page in the emoji / sticker / GIF
  keyboard.
- `GiphyMp4Fragment` renders a two-column staggered grid.
- `GifQuickSearchOption` provides ranked quick searches: trending, celebrate,
  love, thumbs up, surprised, excited, sad, angry.
- `GiphyMp4PagedDataSource` pages trending/search results from GIPHY.
- `GiphyImage` chooses the largest GIF/MP4 rendition under a 2 MB cap.
- `GiphyMp4ViewHolder` displays still thumbnails and MP4 previews.
- `GiphyMp4PlaybackController` only animates a bounded set of center-most
  visible items.
- `GiphyMp4Repository` downloads the selected sendable asset into the normal
  media pipeline.

The key lesson is separation: animated search previews are optimized for
scrolling, while selected GIFs become normal media attachments.

## Chosen approach

Use provider abstraction with a Sonar-native Nostr catalog source.

The app should consume a provider-neutral `SonarGifCatalog` model. GIPHY can be
one provider later, but Sonar should also support public Nostr GIF catalogs so a
user can save a catalog from another Sonar user and include it in their own app.

## Nostr catalog protocol

Use NIP-78-style replaceable events:

- kind: `30078`
- `d` tag: `sonar.gif.catalog.v1`
- tags: `["t", "sonar"]`, `["t", "gif"]`
- content: JSON

Content shape:

```json
{
  "schema": 1,
  "app": "sonar",
  "type": "gif_catalog",
  "name": "Reactions",
  "items": [
    {
      "id": "stable-item-id",
      "title": "thumbs up",
      "mime": "video/mp4",
      "url": "https://blossom.example/<blob>",
      "preview_url": "https://blossom.example/<preview>",
      "still_url": "https://blossom.example/<still>",
      "width": 480,
      "height": 270,
      "bytes": 734201,
      "source": "nostr"
    }
  ]
}
```

Rules:

- All media URLs must be `https://`.
- Allowed send MIME types are `image/gif`, `video/mp4`, and `image/webp`.
- A catalog has at most 64 items.
- A sendable item is capped at 25 MB, matching Sonar's encrypted media download
  ceiling.
- Clients must not auto-download catalog items. Download only when previewing or
  sending.
- Sending a public catalog GIF does not send the public URL directly to the
  private chat. The client downloads the selected public asset, then re-encrypts
  and uploads it through `sendMedia`, producing a normal Marmot MIP-04 media
  message.

## Implementation phases

### Phase 1: Shared contract

Add validated catalog models on both app surfaces:

- Compose: `SonarGifCatalog` / `SonarGifItem` in `commonMain`.
- Apple: matching `SonarGifCatalog` / `SonarGifItem` with `Codable`.
- Tests for URL validation, size caps, MIME allowlist, stable ID derivation, and
  Nostr JSON encoding.

This phase is the current shipped slice.

### Phase 2: Local saved catalog UI

Add a GIF tab in the composer sheet that lists locally saved catalogs. The first
catalog source is local Nostr catalog JSON imported from a known event or copied
catalog payload. Tapping an item downloads it with size/type checks and sends it
through the existing encrypted media path.

### Phase 3: Nostr discovery

Extend the shared Rust core with:

- `publish_gif_catalog`
- `fetch_gif_catalog(author)`
- `search_gif_catalogs(tag/query/followed-authors)`

The core should validate the same schema before returning catalog items to the
apps. Relay requests should be scoped and paginated; catalogs are public, so
never include private chat context in the event.

### Phase 4: Signal-style provider UI

Add a full GIF keyboard:

- search field
- quick category chips
- staggered grid
- still thumbnails
- bounded MP4 autoplay for visible center-most items
- loading / empty / error states
- provider attribution when required

Android should use Media3/ExoPlayer for MP4 previews. Apple should use AVPlayer.
Desktop can use still previews first if inline MP4 playback is not yet available,
but that must be tracked as a platform gap.

### Phase 5: Optional third-party provider

Add GIPHY or another provider only after product/legal/privacy decisions:

- API key owner and secret handling
- attribution and analytics requirements
- Tor/proxy behavior
- retention/cache rules
- fallback when the provider is disabled

## Success criteria

- Users can save a public Nostr GIF catalog locally.
- Users can send a saved GIF through encrypted Sonar media.
- Search previews remain performant with many results.
- Received GIFs and MP4 GIFs animate inline and in the media viewer on every
  supported surface, or gaps are explicitly tracked.
- No provider API key is committed.

## Risks

- GIPHY-style providers are not just code; they carry attribution, analytics,
  and proxy/cache policy requirements.
- Public catalogs reveal the catalog publisher's curated media list. That is OK
  for public catalogs, but private favorites must stay local unless the user
  explicitly publishes them.
- MP4 GIF playback needs platform-specific players. Raw `WKWebView`/GIF-only
  rendering is not enough for Signal parity.
