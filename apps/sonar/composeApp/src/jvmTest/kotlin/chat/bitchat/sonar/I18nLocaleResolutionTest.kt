package chat.bitchat.sonar

import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.app_info_close
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
    fun resolvesTraditionalChineseFromScriptLocale() =
        assertEquals("關閉", closeLabelIn("zh-Hant-TW"))

    /** Legacy-code check: modern `he` dir vs the JDK's historical `iw` mapping. */
    @Test
    fun resolvesHebrew() = assertEquals("סגור", closeLabelIn("he-IL"))

    /** Legacy-code check: modern `id` dir vs the JDK's historical `in` mapping. */
    @Test
    fun resolvesIndonesian() = assertEquals("tutup", closeLabelIn("id-ID"))
}
