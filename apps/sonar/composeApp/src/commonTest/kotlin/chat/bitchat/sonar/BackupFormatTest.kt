package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The Settings rows and the backup stats strip render from these, and the design
 * shows the numbers side by side — a rounding difference between platforms would
 * read as a bug.
 */
class BackupFormatTest {

    @Test
    fun unmeasuredValuesRenderAsNothingNotZero() {
        // A dash is honest; "0 B" would claim we measured an empty account.
        assertNull(BackupFormat.bytes(null))
        assertNull(BackupFormat.count(null))
        assertNull(BackupFormat.lastBackup(null, nowSecs = 1_785_200_000, offsetSecs = 0))
        assertNull(BackupFormat.lastBackup(0, nowSecs = 1_785_200_000, offsetSecs = 0))
    }

    @Test
    fun bytesUseDecimalUnitsLikeTheOsStorageScreen() {
        assertEquals("512 B", BackupFormat.bytes(512))
        assertEquals("1.0 kB", BackupFormat.bytes(1_000))
        // Above 10 units the extra digit is noise, so this rounds whole.
        assertEquals("283 kB", BackupFormat.bytes(282_748))
        assertEquals("124 MB", BackupFormat.bytes(124_000_000))
        assertEquals("1.2 GB", BackupFormat.bytes(1_240_000_000))
    }

    /** One decimal below 10 so a small backup does not collapse to "1 MB". */
    @Test
    fun smallValuesKeepADecimalAndLargeOnesDoNot() {
        assertEquals("1.2 MB", BackupFormat.bytes(1_200_000))
        assertEquals("9.9 MB", BackupFormat.bytes(9_900_000))
        assertEquals("10 MB", BackupFormat.bytes(10_000_000))
    }

    @Test
    fun countsAreGrouped() {
        assertEquals("7", BackupFormat.count(7))
        assertEquals("999", BackupFormat.count(999))
        assertEquals("1,204", BackupFormat.count(1_204))
        assertEquals("1,000,000", BackupFormat.count(1_000_000))
    }

    @Test
    fun lastBackupReadsAsTodayYesterdayThenDays() {
        // 1_785_196_800 is a midnight boundary in UTC; build from it so the
        // day arithmetic is exercised rather than assumed.
        val midnight = 1_785_196_800L
        val now = midnight + 10 * 3600 + 30 * 60 // 10:30 the same day

        assertEquals("Today, 04:12", BackupFormat.lastBackup(midnight + 4 * 3600 + 12 * 60, now, offsetSecs = 0))
        assertEquals("Yesterday, 22:40", BackupFormat.lastBackup(midnight - 3600 - 20 * 60, now, offsetSecs = 0))
        assertEquals("3 d ago", BackupFormat.lastBackup(now - 3 * 86_400, now, offsetSecs = 0))
    }

    @Test
    fun aBackupSecondsOldReadsAsJustNow() {
        val now = 1_785_200_000L
        assertEquals("Just now", BackupFormat.lastBackup(now - 5, now, offsetSecs = 0))
        // Clock skew must not produce a negative-duration string.
        assertEquals("Just now", BackupFormat.lastBackup(now + 30, now, offsetSecs = 0))
    }

    @Test
    fun frequencyLabelsMatchTheSettingsSheet() {
        assertEquals("Daily", BackupFormat.frequencyLabel("daily"))
        assertEquals("Weekly", BackupFormat.frequencyLabel("weekly"))
        assertEquals("Manual only", BackupFormat.frequencyLabel("manual"))
        // An unknown value from a newer core must not crash the row.
        assertEquals("Daily", BackupFormat.frequencyLabel("hourly"))
    }
}
