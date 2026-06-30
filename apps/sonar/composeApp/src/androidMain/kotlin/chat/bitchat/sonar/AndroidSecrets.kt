package chat.bitchat.sonar

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small Android-only secret store. Ciphertexts live in app-private preferences,
 * while the AES-GCM key is non-exportable and held by Android Keystore.
 */
internal object AndroidSecrets {
    private const val KEY_ALIAS = "sonar.android.secrets.v1"
    private const val PREFS_NAME = "sonar.secrets"
    private const val LEGACY_PREFS_NAME = "sonar"
    private const val VERSION = "v1"
    private const val GCM_TAG_BITS = 128

    private val ctx: Context get() = AppContextHolder.ctx
    private fun secretsPrefs() = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private fun legacyPrefs() = ctx.getSharedPreferences(LEGACY_PREFS_NAME, Context.MODE_PRIVATE)

    fun get(key: String): String? =
        secretsPrefs().getString(key, null)?.let { decrypt(it) }

    fun getMigrating(key: String, durable: Boolean = false): String? {
        secretsPrefs().getString(key, null)?.let {
            val value = decrypt(it)
            legacyPrefs().edit().remove(key).apply()
            return value
        }
        val legacy = legacyPrefs().getString(key, null) ?: return null
        put(key, legacy, durable = durable)
        return legacy
    }

    fun put(key: String, value: String, durable: Boolean = false) {
        val edit = secretsPrefs().edit().putString(key, encrypt(value))
        if (durable) {
            check(edit.commit()) { "Failed to persist Android secret: $key" }
        } else {
            edit.apply()
        }
        legacyPrefs().edit().remove(key).apply()
    }

    fun clear() {
        secretsPrefs().edit().clear().apply()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return listOf(
            VERSION,
            cipher.iv.b64(),
            cipher.doFinal(value.encodeToByteArray()).b64(),
        ).joinToString(":")
    }

    private fun decrypt(stored: String): String {
        val parts = stored.split(":")
        require(parts.size == 3 && parts[0] == VERSION) { "Unsupported secret format" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(GCM_TAG_BITS, parts[1].unb64()),
        )
        return cipher.doFinal(parts[2].unb64()).decodeToString()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private fun ByteArray.b64(): String = Base64.encodeToString(this, Base64.NO_WRAP)
    private fun String.unb64(): ByteArray = Base64.decode(this, Base64.NO_WRAP)
}
