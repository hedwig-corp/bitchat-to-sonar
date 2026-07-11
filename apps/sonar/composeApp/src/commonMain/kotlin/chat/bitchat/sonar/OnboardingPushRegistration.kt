package chat.bitchat.sonar

/**
 * Retry mobile push registration only after onboarding has durably stored an
 * account key. Android's application-level registration runs before a fresh
 * install finishes onboarding, so that first attempt intentionally does
 * nothing; this retry shares the device token once the account is ready.
 */
internal fun retryPushRegistrationAfterAccountReady(
    hasIdentity: () -> Boolean = SonarCore::hasIdentity,
    retryRegistration: () -> Unit = { Notifier.setPushEnabled(true) },
) {
    if (hasIdentity()) retryRegistration()
}
