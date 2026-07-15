const ANDROID_PACKAGE = "chat.bitchat.sonar";
const INSTALL_URL = "https://github.com/hedwig-corp/bitchat-to-sonar/releases/latest";

/** Extract the same well-formed token candidate that the Rust core normalizes. */
export function inviteTokenFromHash(hash) {
  return /sinvite1[0-9a-fA-F]+/.exec(hash || "")?.[0] ?? null;
}

/** Build the user-initiated app handoff for the current browser platform. */
export function openInSonarHref(token, userAgent) {
  if (/Android/i.test(userAgent || "")) {
    // Target Sonar explicitly. Android browsers handle this more reliably than
    // an unqualified custom scheme and can fall back to the install page.
    return "intent://invite/" + token
      + "#Intent;scheme=sonar;package=" + ANDROID_PACKAGE
      + ";S.browser_fallback_url=" + encodeURIComponent(INSTALL_URL) + ";end";
  }
  return "sonar://invite/" + token;
}

export function configureOpenInSonar(location, navigator, document) {
  const token = inviteTokenFromHash(location.hash);
  if (!token) return;
  document.getElementById("open")?.setAttribute(
    "href",
    openInSonarHref(token, navigator.userAgent),
  );
}

if (typeof window !== "undefined") {
  configureOpenInSonar(window.location, window.navigator, window.document);
}
