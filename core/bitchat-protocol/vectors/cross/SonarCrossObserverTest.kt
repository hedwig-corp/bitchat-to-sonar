package com.bitchat.android.protocol

import com.bitchat.android.model.AuthenticatedPeerState
import com.bitchat.android.model.BitchatFilePacket
import com.bitchat.android.model.FragmentPayload
import com.bitchat.android.model.IdentityAnnouncement
import com.bitchat.android.model.NoisePayload
import com.bitchat.android.model.NoisePayloadType
import com.bitchat.android.model.PeerCapabilities
import com.bitchat.android.model.PrivateMessagePacket
import com.bitchat.android.noise.NoisePeerIdentity
import com.google.gson.GsonBuilder
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.junit.Test
import java.io.File

/**
 * Runs inside permissionlesstech/bitchat-android's unit-test harness (installed by
 * scripts/bitchat-vectors/cross-replay.sh). Feeds every neutral operation produced by
 * scripts/bitchat-vectors/cross.py to the real Android codec and writes what it returned.
 * It judges nothing: cross.py compares the outputs with the codec that produced the
 * vectors and classifies every difference.
 *
 * SONAR_CROSS_OPS      colon-separated list of ops files
 * SONAR_CROSS_OUT_DIR  results land here as results-<source>.json
 */
class SonarCrossObserverTest {

    private class Unsupported(val why: String) : Exception(why)

    private fun hex(b: ByteArray?): String? = b?.joinToString("") { "%02x".format(it) }

    private fun unhex(s: String): ByteArray {
        if (s.startsWith("repeat:")) {
            val (b, n) = s.removePrefix("repeat:").split("*")
            return ByteArray(n.toInt()) { b.toInt(16).toByte() }
        }
        return ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
    }

    private fun JsonObject.opt(k: String): JsonElement? = get(k)?.takeUnless { it.isJsonNull }
    private fun JsonObject.bytes(k: String): ByteArray? = opt(k)?.asString?.let { unhex(it) }
    private fun JsonObject.str(k: String): String? = opt(k)?.asString
    private fun JsonObject.int(k: String): Int? = opt(k)?.asInt
    private fun JsonObject.bool(k: String): Boolean? = opt(k)?.asBoolean
    /** 64-bit values travel as decimal strings; Android keeps them in a signed Long. */
    private fun JsonObject.u64(k: String): Long? = opt(k)?.asString?.toULong()?.toLong()
    private fun JsonObject.hexList(k: String): List<ByteArray>? = opt(k)?.asJsonArray?.map { unhex(it.asString) }

    private fun u64(v: Long): String = v.toULong().toString()

    private fun packet(i: JsonObject): BitchatPacket {
        if (i.bool("is_rsr") == true) throw Unsupported("BitchatPacket has no RSR flag on Android")
        return BitchatPacket(
            version = i.int("version")!!.toUByte(),
            type = i.int("type")!!.toUByte(),
            senderID = i.bytes("sender")!!,
            recipientID = i.bytes("recipient"),
            timestamp = i.str("timestamp")!!.toULong(),
            payload = i.bytes("payload")!!,
            signature = i.bytes("signature"),
            ttl = i.int("ttl")!!.toUByte(),
            route = i.hexList("route")
        )
    }

    private fun observe(op: String, i: JsonObject): Map<String, Any?> = when (op) {
        "compress_decision" -> mapOf("result" to CompressionUtil.shouldCompress(i.bytes("payload")!!))
        "compress" -> mapOf("compressed" to hex(CompressionUtil.compress(i.bytes("payload")!!)))
        "inflate" -> mapOf("payload" to hex(CompressionUtil.decompress(i.bytes("stream")!!, i.int("size")!!)))
        "pad" -> mapOf("padded" to hex(MessagePadding.pad(i.bytes("data")!!, i.int("target")!!)))
        "unpad" -> mapOf("unpadded" to hex(MessagePadding.unpad(i.bytes("data")!!)))
        "block" -> mapOf("block" to MessagePadding.optimalBlockSize(i.int("size")!!))
        "packet_encode" -> {
            val p = packet(i)
            mapOf(
                "padded" to hex(BinaryProtocol.encode(p, padding = true)),
                "unpadded" to hex(BinaryProtocol.encode(p, padding = false)),
                "preimage" to hex(p.toBinaryDataForSigning())
            )
        }
        "packet_decode" -> {
            val d = BinaryProtocol.decode(i.bytes("bytes")!!)
            if (d == null) mapOf("decodes" to false) else mapOf(
                "decodes" to true,
                "version" to d.version.toInt(), "type" to d.type.toInt(), "ttl" to d.ttl.toInt(),
                "timestamp" to d.timestamp.toString(), "sender" to hex(d.senderID),
                "recipient" to hex(d.recipientID), "route" to d.route?.map { hex(it) },
                "payload" to hex(d.payload), "signature" to hex(d.signature),
                // The verify path: what a receiver checks the signature against.
                "preimage" to hex(d.toBinaryDataForSigning()),
                // The relay path: what a receiver forwards.
                "reencoded_unpadded" to hex(BinaryProtocol.encode(d, padding = false)),
                "reencoded_padded" to hex(BinaryProtocol.encode(d, padding = true))
            )
        }
        "peer_id" -> mapOf("peer_id" to NoisePeerIdentity.derivePeerID(i.bytes("key")!!))
        "caps_encode" -> mapOf("encoded" to hex(PeerCapabilities(i.u64("raw")!!).encoded()))
        "caps_decode" -> {
            val c = PeerCapabilities.decode(i.bytes("bytes")!!)
            mapOf("raw" to u64(c.rawValue), "reencoded" to hex(c.encoded()))
        }
        "announce_encode" -> {
            if (i.opt("neighbors") != null) throw Unsupported("IdentityAnnouncement has no direct-neighbors field")
            if (i.opt("geohash") != null) throw Unsupported("IdentityAnnouncement has no bridge-geohash field")
            val a = IdentityAnnouncement(
                nickname = i.str("nickname")!!, noisePublicKey = i.bytes("noise")!!,
                signingPublicKey = i.bytes("signing")!!, capabilities = i.u64("caps")?.let { PeerCapabilities(it) }
            )
            mapOf("encoded" to hex(a.encode()))
        }
        "announce_decode" -> {
            val a = IdentityAnnouncement.decode(i.bytes("bytes")!!)
            if (a == null) mapOf("decodes" to false) else mapOf(
                "decodes" to true, "nickname" to a.nickname, "noise" to hex(a.noisePublicKey),
                "signing" to hex(a.signingPublicKey), "caps" to a.capabilities?.let { u64(it.rawValue) },
                "reencoded" to hex(a.encode())
            )
        }
        "peer_state_encode" -> mapOf(
            // Android refuses a malformed key by throwing where iOS returns nil; both
            // mean "no encoding".
            "encoded" to try {
                hex(AuthenticatedPeerState(PeerCapabilities(i.u64("caps")!!), i.bytes("signing")!!).encode())
            } catch (e: IllegalArgumentException) {
                null
            }
        )
        "peer_state_decode" -> {
            val p = AuthenticatedPeerState.decode(i.bytes("bytes")!!)
            if (p == null) mapOf("decodes" to false)
            else mapOf("decodes" to true, "caps" to u64(p.capabilities.rawValue), "signing" to hex(p.signingPublicKey))
        }
        "pm_encode" -> mapOf("encoded" to hex(PrivateMessagePacket(i.str("message_id")!!, i.str("content")!!).encode()))
        "pm_decode" -> {
            val p = PrivateMessagePacket.decode(i.bytes("bytes")!!)
            if (p == null) mapOf("decodes" to false)
            else mapOf("decodes" to true, "message_id" to p.messageID, "content" to p.content)
        }
        "noise_encode" -> {
            val t = NoisePayloadType.entries.firstOrNull { it.value.toInt() == i.int("type")!! }
                ?: throw Unsupported("NoisePayloadType ${i.int("type")} unknown to this build")
            mapOf("encoded" to hex(NoisePayload(t, i.bytes("data")!!).encode()))
        }
        "noise_decode" -> {
            val p = NoisePayload.decode(i.bytes("bytes")!!)
            if (p == null) mapOf("decodes" to false)
            else mapOf("decodes" to true, "type" to p.type.value.toInt(), "data" to hex(p.data), "reencoded" to hex(p.encode()))
        }
        "file_encode" -> {
            val name = i.str("name") ?: throw Unsupported("BitchatFilePacket requires a file name")
            val mime = i.str("mime") ?: throw Unsupported("BitchatFilePacket requires a MIME type")
            val content = i.bytes("content")!!
            // A sender that omits the size means "the content length" (iOS resolves it
            // that way in encode()); Android's constructor takes it explicitly.
            val size = i.u64("size") ?: content.size.toLong()
            mapOf("encoded" to hex(BitchatFilePacket(name, size, mime, content).encode()))
        }
        "file_decode" -> {
            val f = BitchatFilePacket.decode(i.bytes("bytes")!!)
            if (f == null) mapOf("decodes" to false) else mapOf(
                "decodes" to true, "name" to f.fileName, "size" to u64(f.fileSize), "mime" to f.mimeType,
                "content" to hex(f.content), "reencoded" to hex(f.encode())
            )
        }
        "fragment_encode" -> mapOf(
            "encoded" to hex(
                FragmentPayload(i.bytes("fragment_id")!!, i.int("index")!!, i.int("total")!!,
                    i.int("type")!!.toUByte(), i.bytes("data")!!).encode()
            )
        )
        "fragment_decode" -> {
            val f = FragmentPayload.decode(i.bytes("payload")!!)
            if (f == null) mapOf("decodes" to false) else mapOf(
                "decodes" to true, "fragment_id" to hex(f.fragmentID), "index" to f.index, "total" to f.total,
                "type" to f.originalType.toInt(), "data" to hex(f.data)
            )
        }
        else -> throw Unsupported("unknown op $op")
    }

    @Test
    fun observe() {
        val list = System.getenv("SONAR_CROSS_OPS") ?: return
        val outDir = System.getenv("SONAR_CROSS_OUT_DIR") ?: return
        val gson = GsonBuilder().serializeNulls().create()
        for (path in list.split(":").filter { it.isNotBlank() }) {
            val root = JsonParser.parseString(File(path).readText()).asJsonObject
            val source = root.get("source")?.asString ?: "unknown"
            val ops = root.getAsJsonArray("ops")
            val results = ops.map { e ->
                val op = e.asJsonObject
                val id = op.get("id").asString
                try {
                    mapOf("id" to id, "out" to observe(op.get("op").asString, op.getAsJsonObject("in")))
                } catch (u: Unsupported) {
                    mapOf("id" to id, "unsupported" to u.why)
                } catch (t: Throwable) {
                    mapOf("id" to id, "error" to "${t::class.simpleName}: ${t.message}")
                }
            }
            val dest = File(outDir, "results-$source.json")
            dest.writeText(gson.toJson(mapOf("observer" to "android", "source" to source, "results" to results)))
            println("CROSS observer=android source=$source ops=${ops.size()} -> ${dest.path}")
        }
    }
}
