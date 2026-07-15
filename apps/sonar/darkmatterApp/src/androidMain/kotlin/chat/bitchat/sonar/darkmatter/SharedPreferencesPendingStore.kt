package chat.bitchat.sonar.darkmatter

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

class EncryptedPreferencesPendingStore(
    private val preferences: SharedPreferences,
) : PendingConversationStore {
    override suspend fun load(): List<PendingConversation> = withContext(Dispatchers.IO) {
        val encoded = preferences.getString(STORE_KEY, null) ?: return@withContext emptyList()
        decode(decrypt(encoded))
    }

    override suspend fun save(conversations: List<PendingConversation>) = withContext(Dispatchers.IO) {
        if (conversations.isEmpty()) {
            check(preferences.edit().remove(STORE_KEY).commit()) {
                "Unable to clear the pending Darkmatter outbox."
            }
        } else {
            val encoded = encrypt(
                encode(conversations.take(DarkmatterController.MAX_PENDING_CONVERSATIONS)),
            )
            check(preferences.edit().putString(STORE_KEY, encoded).commit()) {
                "Unable to persist the pending Darkmatter outbox."
            }
        }
    }

    private fun encrypt(plaintext: String): String {
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        cipher.updateAAD(ASSOCIATED_DATA)
        val ciphertext = cipher.doFinal(plaintext.toByteArray(StandardCharsets.UTF_8))
        return JSONObject()
            .put("version", ENCRYPTION_VERSION)
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            .toString()
    }

    private fun decrypt(envelope: String): String {
        val root = JSONObject(envelope)
        check(root.optInt("version") == ENCRYPTION_VERSION) {
            "Unsupported pending outbox encryption version."
        }
        val iv = Base64.decode(root.getString("iv"), Base64.NO_WRAP)
        val ciphertext = Base64.decode(root.getString("ciphertext"), Base64.NO_WRAP)
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        cipher.updateAAD(ASSOCIATED_DATA)
        return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    @Synchronized
    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        val existing = keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) return existing.secretKey

        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    internal fun encode(conversations: List<PendingConversation>): String {
        val root = JSONObject().put("version", FORMAT_VERSION)
        val items = JSONArray()
        conversations.forEach { conversation ->
            val messages = JSONArray()
            conversation.messages
                .takeLast(DarkmatterController.MAX_QUEUED_MESSAGES)
                .forEach { message ->
                    messages.put(
                        JSONObject()
                            .put("id", message.id)
                            .put("text", message.text.take(DarkmatterController.MAX_MESSAGE_LENGTH))
                            .put("created_at", message.createdAtSeconds)
                            .put("delivery", message.delivery.name)
                            .putOpt("error", message.error),
                    )
                }
            items.put(
                JSONObject()
                    .put("id", conversation.id)
                    .put(
                        "member_ref",
                        conversation.memberReference.take(DarkmatterController.MAX_MEMBER_REFERENCE_LENGTH),
                    )
                    .put("title", conversation.title.take(DarkmatterController.MAX_TITLE_LENGTH))
                    .put("created_at", conversation.createdAtSeconds)
                    .putOpt("group_id", conversation.resolvedGroupId)
                    .putOpt("setup_error", conversation.setupError)
                    .put("messages", messages),
            )
        }
        return root.put("conversations", items).toString()
    }

    internal fun decode(encoded: String): List<PendingConversation> {
        val root = JSONObject(encoded)
        if (root.optInt("version") != FORMAT_VERSION) return emptyList()
        val items = root.optJSONArray("conversations") ?: return emptyList()
        return buildList {
            for (index in 0 until minOf(items.length(), DarkmatterController.MAX_PENDING_CONVERSATIONS)) {
                val item = items.optJSONObject(index) ?: continue
                val id = item.optString("id").takeIf(String::isNotBlank) ?: continue
                val member = item.optString("member_ref")
                    .take(DarkmatterController.MAX_MEMBER_REFERENCE_LENGTH)
                if (member.isBlank()) continue
                val messagesJson = item.optJSONArray("messages") ?: JSONArray()
                val messages = buildList {
                    val start = (messagesJson.length() - DarkmatterController.MAX_QUEUED_MESSAGES)
                        .coerceAtLeast(0)
                    for (messageIndex in start until messagesJson.length()) {
                        val message = messagesJson.optJSONObject(messageIndex) ?: continue
                        val messageId = message.optString("id").takeIf(String::isNotBlank) ?: continue
                        val text = message.optString("text").take(DarkmatterController.MAX_MESSAGE_LENGTH)
                        if (text.isBlank()) continue
                        val delivery = runCatching {
                            DarkmatterDelivery.valueOf(message.optString("delivery"))
                        }.getOrDefault(DarkmatterDelivery.QUEUED)
                        add(
                            PendingMessage(
                                id = messageId,
                                text = text,
                                createdAtSeconds = message.optLong("created_at"),
                                delivery = delivery,
                                error = message.optNullableString("error"),
                            ),
                        )
                    }
                }
                add(
                    PendingConversation(
                        id = id,
                        memberReference = member,
                        title = item.optString("title", "Darkmatter chat")
                            .take(DarkmatterController.MAX_TITLE_LENGTH),
                        createdAtSeconds = item.optLong("created_at"),
                        resolvedGroupId = item.optNullableString("group_id"),
                        messages = messages,
                        setupError = item.optNullableString("setup_error"),
                    ),
                )
            }
        }
    }

    private fun JSONObject.optNullableString(name: String): String? =
        if (isNull(name)) null else optString(name).takeIf(String::isNotBlank)

    companion object {
        private const val STORE_KEY = "pending_conversations_v1"
        private const val FORMAT_VERSION = 1
        private const val ENCRYPTION_VERSION = 1
        private const val ANDROID_KEY_STORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "sonar_darkmatter_pending_v1"
        private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private val ASSOCIATED_DATA = "sonar-darkmatter-pending-v1"
            .toByteArray(StandardCharsets.UTF_8)
    }
}
