package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DesktopSecretsTest {
    private class FakeBackend(
        private val proofs: ArrayDeque<DesktopSecretLookup>,
        private val deleteResult: Boolean = true,
        private val ordinaryLookup: DesktopSecretLookup = DesktopSecretLookup.Absent,
    ) : DesktopSecretBackend {
        var deletes = 0
        override fun lookup(key: String): DesktopSecretLookup = ordinaryLookup
        override fun proveAbsent(key: String): DesktopSecretLookup = proofs.removeFirst()
        override fun put(key: String, value: String): Boolean = true
        override fun delete(key: String): Boolean { deletes += 1; return deleteResult }
    }

    @Test
    fun lockedOrUnavailableStoreCannotCommitWipe() {
        val backend = FakeBackend(ArrayDeque(listOf(DesktopSecretLookup.Unavailable)))
        assertFalse(deleteAndProveSecretAbsent(backend, "nsec"))
        assertTrue(backend.deletes == 0)
    }

    @Test
    fun ordinaryLookupMissCannotHideLockedCollection() {
        val backend = FakeBackend(
            proofs = ArrayDeque(listOf(DesktopSecretLookup.Unavailable)),
            ordinaryLookup = DesktopSecretLookup.Absent,
        )
        assertFalse(deleteAndProveSecretAbsent(backend, "nsec"))
        assertTrue(backend.deletes == 0)
    }

    @Test
    fun duplicateRemainingAfterDeleteCannotCommitWipe() {
        val backend = FakeBackend(ArrayDeque(listOf(
            DesktopSecretLookup.Found("old"),
            DesktopSecretLookup.Found("locked-duplicate"),
        )))
        assertFalse(deleteAndProveSecretAbsent(backend, "nsec"))
        assertTrue(backend.deletes == 1)
    }

    @Test
    fun deleteCommitsOnlyAfterPositiveAbsence() {
        val backend = FakeBackend(ArrayDeque(listOf(
            DesktopSecretLookup.Found("old"),
            DesktopSecretLookup.Absent,
        )))
        assertTrue(deleteAndProveSecretAbsent(backend, "nsec"))
        assertTrue(backend.deletes == 1)
    }

    @Test
    fun successfulEmptySecretToolSearchProvesAbsence() {
        assertTrue(
            classifySecretToolSearch(status = 0, stdout = "", stderr = "") ==
                DesktopSecretLookup.Absent
        )
    }

    @Test
    fun successfulSecretToolSearchWithItemOutputFindsSecret() {
        assertTrue(
            classifySecretToolSearch(
                status = 0,
                stdout = "[item]\nlabel = sonar\nsecret = hidden",
                stderr = "",
            ) is DesktopSecretLookup.Found
        )
    }

    @Test
    fun anyFailedSecretToolSearchRemainsUnavailable() {
        assertTrue(
            classifySecretToolSearch(status = 1, stdout = "", stderr = "") ==
                DesktopSecretLookup.Unavailable
        )
        assertTrue(
            classifySecretToolSearch(status = 2, stdout = "", stderr = "locked") ==
                DesktopSecretLookup.Unavailable
        )
        assertTrue(
            classifySecretToolSearch(status = 0, stdout = "", stderr = "keyring error") ==
                DesktopSecretLookup.Unavailable
        )
    }
}
