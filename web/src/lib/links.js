// Outward links surfaced on the landing page.

// iPhone beta — TestFlight invite.
export const TESTFLIGHT_URL = 'https://testflight.apple.com/join/7pr7S9Me';
// macOS beta — same TestFlight app/group as iPhone, so the same invite link.
export const TESTFLIGHT_MACOS_URL = TESTFLIGHT_URL;
// Android alpha — APK attached to the GitHub release.
export const ANDROID_APK_URL =
	'https://github.com/hedwig-corp/bitchat-to-sonar/releases/download/v0.1-alpha.13.3/sonar-0.1-alpha.13.3-android.apk';
// Linux desktop alpha — .deb attached to the GitHub release.
//
// Deliberately the releases INDEX rather than a version-pinned asset URL like the
// APK above. The asset name embeds the version (sonar-<version>-linux-amd64.deb),
// so a pinned link has to be bumped by hand every release, and until a release
// carrying a Linux artifact exists any pinned URL is a live 404.
//
// Not /releases/latest either: every Sonar release is a PRE-release, and GitHub's
// "latest" excludes those, so /releases/latest 302s to /releases anyway (verified:
// the API returns 404 for it). Linking the index directly means the redirect is
// not load-bearing and the destination is what a reader actually gets.
//
// Switch to a pinned asset URL alongside the APK bump once that is part of the
// release routine.
export const LINUX_RELEASES_URL =
	'https://github.com/hedwig-corp/bitchat-to-sonar/releases';

// Android via Zapstore (signed package, updates over Nostr).
export const ZAPSTORE_URL = 'https://zapstore.dev/apps/chat.bitchat.sonar';

// In-page anchor to the download section.
export const DOWNLOAD_HREF = '#download';

// Status page subscribe target. Prefer njump when STATUS_NPUB is set in status-data.js;
// until an ops publisher key is chosen, point readers at public Nostr docs.
export const STATUS_SUBSCRIBE_URL = 'https://njump.me';
