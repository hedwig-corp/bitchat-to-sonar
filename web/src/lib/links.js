// Outward links surfaced on the landing page.

// iPhone beta — TestFlight invite.
export const TESTFLIGHT_URL = 'https://testflight.apple.com/join/7pr7S9Me';
// macOS beta — same TestFlight app/group as iPhone, so the same invite link.
export const TESTFLIGHT_MACOS_URL = TESTFLIGHT_URL;
// Android alpha — APK attached to the GitHub release.
export const ANDROID_APK_URL =
	'https://github.com/hedwig-corp/bitchat-to-sonar/releases/download/v0.1-alpha.12.1/sonar-0.1-alpha.12.1-android.apk';
// Android via Zapstore (signed package, updates over Nostr).
export const ZAPSTORE_URL = 'https://zapstore.dev/apps/chat.bitchat.sonar';

// In-page anchor to the download section.
export const DOWNLOAD_HREF = '#download';

// Status page subscribe target. Prefer njump when STATUS_NPUB is set in status-data.js;
// until an ops publisher key is chosen, point readers at public Nostr docs.
export const STATUS_SUBSCRIBE_URL = 'https://njump.me';
