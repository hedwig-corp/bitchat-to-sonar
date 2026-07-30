package chat.bitchat.sonar

/**
 * Whether importing [incomingNpub] should replace the account on this device.
 *
 * Importing an `nsec` is an account replacement: wallet storage, host caches
 * and the Marmot store are wiped, then chats are restored from Blossom. For the
 * account **already signed in** that trades a live database for whatever was
 * last uploaded — and for anyone who never opened the backup screen, nothing
 * was ever uploaded, so it destroys every chat with nothing to restore.
 *
 * Three cases, and they do not fail safe in the same direction:
 *
 * - **Same account ⇒ false.** Re-pasting your own key must be a no-op. This is
 *   the direction that loses data, and it is the reason this function exists.
 * - **Unknown current account ⇒ true.** A blank current npub means onboarding
 *   or a fresh install; refusing there would break restore-on-a-new-phone,
 *   which is the entire point of having a backup. Doubt is safe here only
 *   because there is nothing on the device to lose.
 * - **Unusable incoming key ⇒ false.** A blank incoming npub must never
 *   authorise a wipe. Callers validate the `nsec` before reaching this, so it
 *   should be unreachable — but "replace the account based on nothing" is the
 *   one answer that can never be right, so it is refused explicitly rather
 *   than left to the comparison below.
 */
fun shouldReplaceAccount(currentNpub: String?, incomingNpub: String): Boolean {
    val current = normalizeNpub(currentNpub)
    val incoming = normalizeNpub(incomingNpub)
    if (incoming.isEmpty()) return false
    if (current.isEmpty()) return true
    return current != incoming
}

/**
 * Normalize for comparison. Must stay byte-identical to the Swift mirror: the
 * two platforms disagreeing on what "same account" means is itself the bug.
 *
 * Trims an explicit ASCII set rather than [String.trim], whose `isWhitespace`
 * differs from Swift's `.whitespacesAndNewlines` on U+00A0 and friends — a
 * non-breaking space around a pasted key would be a no-op on iOS and a wipe on
 * Android. Lowercases because bech32 is case-insensitive: `NPUB1…` and
 * `npub1…` decode to the same key, and treating them as different accounts
 * fails open on the destructive side.
 */
private fun normalizeNpub(value: String?): String =
    value.orEmpty().trim { it == ' ' || it == '\t' || it == '\r' || it == '\n' }.lowercase()
