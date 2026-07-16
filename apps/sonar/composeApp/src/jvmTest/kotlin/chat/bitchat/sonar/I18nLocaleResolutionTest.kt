package chat.bitchat.sonar

import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.active
import chat.bitchat.sonar.resources.app_info_close
import chat.bitchat.sonar.resources.app_info_how_to_use_start_dm
import chat.bitchat.sonar.resources.geohash_people_you_suffix
import chat.bitchat.sonar.resources.paste_the
import kotlinx.coroutines.runBlocking
import org.jetbrains.compose.resources.getString
import java.util.Locale
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Verifies the generated Compose string resources actually resolve at runtime for
 * the locale qualifiers the generator emits. This guards the silent failure mode:
 * a qualifier the build accepts but the runtime never matches would just render
 * English with no error.
 *
 * `app_info_close` is used because it is one of the keys that genuinely carries
 * translations in the iOS catalog.
 */
class I18nLocaleResolutionTest {
    private val original: Locale = Locale.getDefault()

    @AfterTest
    fun restoreLocale() = Locale.setDefault(original)

    private fun closeLabelIn(languageTag: String): String {
        Locale.setDefault(Locale.forLanguageTag(languageTag))
        return runBlocking { getString(Res.string.app_info_close) }
    }

    @Test
    fun resolvesEnglishByDefault() = assertEquals("close", closeLabelIn("en-US"))

    @Test
    fun resolvesJapanese() = assertEquals("閉じる", closeLabelIn("ja-JP"))

    @Test
    fun resolvesGerman() = assertEquals("schließen", closeLabelIn("de-DE"))

    /** The qualifier that CMP 1.7.3 rejected as `b+zh+Hans`; now `values-zh-rCN`. */
    @Test
    fun resolvesSimplifiedChineseFromScriptLocale() =
        assertEquals("关闭", closeLabelIn("zh-Hans-CN"))

    @Test
    fun resolvesSimplifiedChineseInSingapore() =
        assertEquals("关闭", closeLabelIn("zh-Hans-SG"))

    @Test
    fun resolvesLanguageOnlyChineseFallback() =
        assertEquals("关闭", closeLabelIn("zh"))

    @Test
    fun resolvesTraditionalChineseFromScriptLocale() =
        assertEquals("關閉", closeLabelIn("zh-Hant-TW"))

    @Test
    fun resolvesTraditionalChineseInHongKong() =
        assertEquals("關閉", closeLabelIn("zh-Hant-HK"))

    @Test
    fun resolvesTraditionalChineseInMacau() =
        assertEquals("關閉", closeLabelIn("zh-Hant-MO"))

    /** Legacy-code check: modern `he` dir vs the JDK's historical `iw` mapping. */
    @Test
    fun resolvesHebrew() = assertEquals("סגור", closeLabelIn("he-IL"))

    /** Legacy-code check: modern `id` dir vs the JDK's historical `in` mapping. */
    @Test
    fun resolvesIndonesian() = assertEquals("tutup", closeLabelIn("id-ID"))

    @Test
    fun preservesComposeEscapingAndBoundaryWhitespace() {
        Locale.setDefault(Locale.forLanguageTag("en-US"))
        runBlocking {
            assertEquals("• tap a peer's name to start a DM", getString(Res.string.app_info_how_to_use_start_dm))
            assertEquals(" (you)", getString(Res.string.geohash_people_you_suffix))
            assertEquals("Paste the ", getString(Res.string.paste_the))
        }
    }

    @Test
    fun formatsNumberedAppleObjectPlaceholder() {
        Locale.setDefault(Locale.forLanguageTag("en-US"))
        assertEquals("3 active", runBlocking { getString(Res.string.active, 3) })
    }
}
