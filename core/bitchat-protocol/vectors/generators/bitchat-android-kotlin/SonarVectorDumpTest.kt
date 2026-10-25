package com.bitchat.android.protocol

import com.bitchat.android.model.BitchatFilePacket
import com.bitchat.android.model.FragmentPayload
import com.bitchat.android.model.IdentityAnnouncement
import com.bitchat.android.model.NoisePayload
import com.bitchat.android.model.NoisePayloadType
import com.bitchat.android.model.PeerCapabilities
import com.bitchat.android.model.PrivateMessagePacket
import com.bitchat.android.noise.NoisePeerIdentity
import org.junit.Test
import java.io.File

/**
 * Dumps byte-exact vectors from the upstream codec so other implementations can be checked
 * against it. Not a behavioural test: it only records what upstream does.
 */
class SonarVectorDumpTest {

    // Where the JSON lands: SONAR_VECTOR_OUT (set by
    // scripts/bitchat-vectors/regenerate.sh) or the module's build directory.
    private val outPath: String =
        System.getenv("SONAR_VECTOR_OUT") ?: "build/sonar-bitchat-android-vectors.json"

    // ---------- helpers ----------

    private fun hex(b: ByteArray?): String? = b?.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String): ByteArray =
        ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
    private fun rep(v: Int, n: Int) = ByteArray(n) { v.toByte() }
    private fun cycle(s: String, n: Int): ByteArray {
        val src = s.toByteArray(Charsets.UTF_8)
        return ByteArray(n) { src[it % src.size] }
    }
    private fun ascii(s: String) = s.toByteArray(Charsets.UTF_8)

    private fun case(name: String, kind: String, input: Map<String, Any?>, expected: Map<String, Any?>) =
        mapOf("name" to name, "kind" to kind, "input" to input, "expected" to expected)

    private fun quote(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c.code < 0x20) sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        return sb.append('"').toString()
    }

    private fun json(v: Any?, sb: StringBuilder, indent: Int) {
        val pad = "  ".repeat(indent)
        val padIn = "  ".repeat(indent + 1)
        when (v) {
            null -> sb.append("null")
            is String -> sb.append(quote(v))
            is Boolean -> sb.append(v.toString())
            is Int, is Long -> sb.append(v.toString())
            is ByteArray -> sb.append(quote(hex(v)!!))
            is Map<*, *> -> {
                if (v.isEmpty()) { sb.append("{}"); return }
                sb.append("{\n")
                val keys = v.keys.map { it as String }.sorted()
                keys.forEachIndexed { i, k ->
                    sb.append(padIn).append(quote(k)).append(": ")
                    json(v[k], sb, indent + 1)
                    if (i < keys.size - 1) sb.append(",")
                    sb.append("\n")
                }
                sb.append(pad).append("}")
            }
            is List<*> -> {
                if (v.isEmpty()) { sb.append("[]"); return }
                sb.append("[\n")
                v.forEachIndexed { i, e ->
                    sb.append(padIn)
                    json(e, sb, indent + 1)
                    if (i < v.size - 1) sb.append(",")
                    sb.append("\n")
                }
                sb.append(pad).append("]")
            }
            else -> throw IllegalArgumentException("unsupported json value: ${v::class}")
        }
    }

    // ---------- packet helper ----------

    private fun makePacket(
        version: Int, type: Int, ttl: Int, ts: Long, sender: String, recipient: String?,
        route: List<String>?, payload: ByteArray, signature: ByteArray?
    ) = BitchatPacket(
        version = version.toUByte(),
        type = type.toUByte(),
        senderID = unhex(sender),
        recipientID = recipient?.let { unhex(it) },
        timestamp = ts.toULong(),
        payload = payload,
        signature = signature,
        ttl = ttl.toUByte(),
        route = route?.map { unhex(it) }
    )

    private fun packetCase(
        name: String, version: Int, type: Int, ttl: Int, ts: Long, sender: String, recipient: String?,
        route: List<String>?, payload: ByteArray, signature: ByteArray?
    ): Pair<Map<String, Any?>, ByteArray?> {
        val pkt = makePacket(version, type, ttl, ts, sender, recipient, route, payload, signature)
        val padded = BinaryProtocol.encode(pkt, padding = true)
        val unpadded = BinaryProtocol.encode(pkt, padding = false)
        val preimage = pkt.toBinaryDataForSigning()
        val decoded = padded?.let { BinaryProtocol.decode(it) }
        val decodedUnpadded = unpadded?.let { BinaryProtocol.decode(it) }
        val input = mapOf(
            "version" to version, "type" to type, "ttl" to ttl, "timestamp" to ts,
            "sender_id" to sender, "recipient_id" to recipient, "route" to route,
            "payload" to payload, "signature" to signature
        )
        val expected = mapOf(
            "padded" to padded,
            "unpadded" to unpadded,
            "signing_preimage" to preimage,
            "decodes" to (decoded != null),
            "decoded_payload" to decoded?.payload,
            "decoded_payload_matches_input" to (decoded?.payload?.contentEquals(payload)),
            "decoded_flags" to unpadded?.get(11)?.toInt()?.and(0xff),
            "decoded_wire_compressed" to decoded?.wirePayload?.compressed,
            "decoded_wire_bytes" to decoded?.wirePayload?.bytes,
            "decoded_route" to decoded?.route?.map { hex(it) },
            "decoded_recipient_id" to decoded?.recipientID,
            "decoded_signature" to decoded?.signature,
            "decoded_ttl" to decoded?.ttl?.toInt(),
            "decoded_timestamp" to decoded?.timestamp?.toLong(),
            "unpadded_decodes" to (decodedUnpadded != null)
        )
        return case(name, "packet_encode", input, expected) to padded
    }

    @Test
    fun dumpVectors() {
        val cases = mutableListOf<Map<String, Any?>>()

        // ---------- should_compress / compress ----------
        val scPayloads = linkedMapOf(
            "99_zero_bytes" to rep(0, 99),
            "100_zero_bytes" to rep(0, 100),
            "100_bytes_0_to_99" to ByteArray(100) { it.toByte() },
            "300_bytes_compress-me" to cycle("compress-me", 300),
            "256_bytes_0_to_255" to ByteArray(256) { it.toByte() },
            "512_bytes_i_mod_256" to ByteArray(512) { (it % 256).toByte() }
        )
        for ((n, p) in scPayloads) {
            cases += case(n, "should_compress", mapOf("payload" to p), mapOf("result" to CompressionUtil.shouldCompress(p)))
        }
        val cPayloads = LinkedHashMap(scPayloads)
        cPayloads["1000_bytes_quick_brown_fox"] = cycle("The quick brown fox jumps over the lazy dog. ", 1000)
        for ((n, p) in cPayloads) {
            val c = CompressionUtil.compress(p)
            val expected = mutableMapOf<String, Any?>("compressed" to c)
            if (c != null) {
                expected["roundtrip_ok"] = CompressionUtil.decompress(c, p.size)?.contentEquals(p)
            }
            cases += case(n, "compress", mapOf("payload" to p), expected)
        }

        // ---------- padding ----------
        val padInputs = listOf(
            Triple("hello_to_8", ascii("hello"), 8),
            Triple("hello_to_16", ascii("hello"), 16),
            Triple("hello_to_256", ascii("hello"), 256),
            Triple("hello_to_261_exceeds_255_pad_bytes", ascii("hello"), 261),
            Triple("empty_to_4", ByteArray(0), 4),
            Triple("16_bytes_to_16_no_room", ByteArray(16) { it.toByte() }, 16),
            Triple("20_bytes_to_16_already_larger", ByteArray(20) { it.toByte() }, 16),
            Triple("one_byte_to_256", byteArrayOf(0x41), 256)
        )
        for ((n, d, t) in padInputs) {
            cases += case(n, "padding", mapOf("data" to d, "target" to t), mapOf("padded" to MessagePadding.pad(d, t)))
        }
        for (s in listOf(0, 10, 239, 240, 241, 495, 496, 497, 1000, 2032, 2033, 3000)) {
            cases += case("size_$s", "optimal_block_size", mapOf("size" to s), mapOf("block" to MessagePadding.optimalBlockSize(s)))
        }
        val unpadInputs = linkedMapOf(
            "valid_padded_hello_to_16" to MessagePadding.pad(ascii("hello"), 16),
            "non_padded_hello" to ascii("hello"),
            "invalid_padding_last_3_mismatch" to byteArrayOf(0x01, 0x02, 0x03, 0x04, 0x04, 0x03),
            "all_ff_256_pad_len_exceeds" to rep(0xff, 16),
            "pad_len_equals_size" to rep(0x04, 4),
            "trailing_zero_byte" to byteArrayOf(0x01, 0x02, 0x00)
        )
        for ((n, d) in unpadInputs) {
            val u = MessagePadding.unpad(d)
            cases += case(n, "unpad", mapOf("data" to d), mapOf("unpadded" to u, "changed" to !u.contentEquals(d)))
        }

        // ---------- packet_encode ----------
        val sender = "1122334455667788"
        val sigA0 = ByteArray(64) { (0xA0 + it).toByte() }
        val sig22 = rep(0x22, 64)
        val route = listOf("0102030405060708", "1112131415161718", "2122232425262728")

        val (c1, p1) = packetCase("1_v1_broadcast_hello_mesh", 1, 2, 7, 1709600000000L, sender, null, null, ascii("Hello mesh"), null)
        cases += c1
        cases += packetCase("2_v1_recipient_signed_private", 1, 2, 7, 1709600000000L, sender, "8877665544332211", null, ascii("Private signed"), sigA0).first
        cases += packetCase("3_v1_broadcast_recipient_100_zero_bytes_compressed", 1, 2, 7, 1709600000000L, sender, "ffffffffffffffff", null, rep(0, 100), null).first
        val (c4, p4) = packetCase("4_v1_300_compress-me_sig22", 1, 2, 7, 1709600000000L, sender, null, null, cycle("compress-me", 300), sig22)
        cases += c4
        cases += packetCase("5_v1_256_bytes_0_to_255_not_compressed", 1, 2, 7, 1709600000000L, sender, null, null, ByteArray(256) { it.toByte() }, null).first
        cases += packetCase("6_v2_route_recipient_route-test", 2, 1, 6, 1720000000000L, sender, "2122232425262728", route, ascii("route-test"), null).first
        cases += packetCase("7_v2_route_compressed_compress-me_x150", 2, 3, 6, 1740000000000L, sender, null, route, cycle("compress-me", 1650), null).first
        cases += packetCase("8_v2_type_0x22_70000_bytes_recipient_signature", 2, 0x22, 7, 1709600000000L, sender, "8877665544332211", null, ByteArray(70000) { ((it * 7) % 251).toByte() }, sigA0).first
        cases += packetCase("9a_v1_65535_zero_bytes_compressed", 1, 2, 7, 1709600000000L, sender, null, null, rep(0, 65535), null).first
        cases += packetCase("9b_v1_65536_zero_bytes_expect_null", 1, 2, 7, 1709600000000L, sender, null, null, rep(0, 65536), null).first

        // ---------- packet_reencode_preserves_wire ----------
        run {
            val padded4 = p4!!
            val unpadded4 = BinaryProtocol.encode(makePacket(1, 2, 7, 1709600000000L, sender, null, null, cycle("compress-me", 300), sig22), padding = false)!!
            val decoded = BinaryProtocol.decode(padded4)!!
            val rePadded = BinaryProtocol.encode(decoded, padding = true)
            val reUnpadded = BinaryProtocol.encode(decoded, padding = false)
            // Same packet re-built WITHOUT the wirePayload: shows whether a fresh compression differs.
            val fresh = decoded.copy(wirePayload = null)
            val freshUnpadded = BinaryProtocol.encode(fresh, padding = false)
            cases += case(
                "case4_decode_then_reencode", "packet_reencode_preserves_wire",
                mapOf("padded" to padded4),
                mapOf(
                    "reencoded" to reUnpadded,
                    "reencoded_padded" to rePadded,
                    "equals_original_unpadded" to (reUnpadded?.contentEquals(unpadded4)),
                    "equals_original_padded" to (rePadded?.contentEquals(padded4)),
                    "decoded_wire_compressed" to decoded.wirePayload?.compressed,
                    "decoded_wire_bytes" to decoded.wirePayload?.bytes,
                    "fresh_reencode_without_wirepayload" to freshUnpadded,
                    "fresh_equals_original_unpadded" to (freshUnpadded?.contentEquals(unpadded4))
                )
            )
        }

        // The same frame carrying a DEFLATE stream no reference encoder emits for this payload:
        // zlib level 1 (python3: zlib.compressobj(1, zlib.DEFLATED, -15)), 18 bytes like the
        // default-level stream above but different bytes. Here a fresh compression differs from
        // the original, so "re-encode reproduces the originator's bytes" is distinguishable from
        // "re-encode recompresses" -- which the case above cannot show.
        run {
            val unpadded4 = BinaryProtocol.encode(makePacket(1, 2, 7, 1709600000000L, sender, null, null, cycle("compress-me", 300), sig22), padding = false)!!
            val own = BinaryProtocol.decode(unpadded4)!!.wirePayload!!.bytes
            val foreign = unhex("4bcecf2d284a2d2ed6cd4d4d1e65e20f0700")
            check(foreign.size == own.size && !foreign.contentEquals(own)) { "foreign stream must differ from the codec's own at equal length" }
            // v1 header (14) + sender (8) + 2-byte original size, then the stream.
            val at = 14 + 8 + 2
            check(unpadded4.copyOfRange(at, at + own.size).contentEquals(own)) { "unexpected frame layout" }
            val frame = unpadded4.copyOf().also { foreign.copyInto(it, at) }
            val padded = MessagePadding.pad(frame, MessagePadding.optimalBlockSize(frame.size))
            val decoded = BinaryProtocol.decode(padded)!!
            val rePadded = BinaryProtocol.encode(decoded, padding = true)
            val reUnpadded = BinaryProtocol.encode(decoded, padding = false)
            val freshUnpadded = BinaryProtocol.encode(decoded.copy(wirePayload = null), padding = false)
            cases += case(
                "case4_foreign_deflate_decode_then_reencode", "packet_reencode_preserves_wire",
                mapOf("padded" to padded),
                mapOf(
                    "reencoded" to reUnpadded,
                    "reencoded_padded" to rePadded,
                    "equals_original_unpadded" to (reUnpadded?.contentEquals(frame)),
                    "equals_original_padded" to (rePadded?.contentEquals(padded)),
                    "decoded_wire_compressed" to decoded.wirePayload?.compressed,
                    "decoded_wire_bytes" to decoded.wirePayload?.bytes,
                    "fresh_reencode_without_wirepayload" to freshUnpadded,
                    "fresh_equals_original_unpadded" to (freshUnpadded?.contentEquals(frame))
                )
            )
        }

        // ---------- packet_decode_reject ----------
        run {
            val unpadded1 = BinaryProtocol.encode(makePacket(1, 2, 7, 1709600000000L, sender, null, null, ascii("Hello mesh"), null), padding = false)!!
            val truncated = unpadded1.copyOfRange(0, 10)
            val v3 = unpadded1.copyOf().also { it[0] = 3 }
            val overrun = unpadded1.copyOf().also { it[12] = 0x10; it[13] = 0x00 }
            // v1, type 2, ttl 7, ts, flags=IS_COMPRESSED, payloadLength=1, sender, one payload byte (0x00)
            val compLen1 = unhex("010207") + unhex("0000018e0b8c7a00") + unhex("04") + unhex("0001") + unhex(sender) + unhex("00")
            val rejects = linkedMapOf(
                "truncated_10_bytes" to truncated,
                "version_3" to v3,
                "payload_length_overruns_data" to overrun,
                "compressed_flag_payload_length_1" to compLen1
            )
            for ((n, d) in rejects) {
                cases += case(n, "packet_decode_reject", mapOf("bytes" to d), mapOf("decodes" to (BinaryProtocol.decode(d) != null)))
            }
        }

        // ---------- announce_tlv ----------
        run {
            val ann = listOf(
                Triple("alice", null as Long?, 1 to 2),
                Triple("bob", 0x100L, 3 to 4),
                Triple("carol", 0x301L, 5 to 6)
            )
            var carolEncoded: ByteArray? = null
            for ((nick, caps, keys) in ann) {
                val a = IdentityAnnouncement(nick, rep(keys.first, 32), rep(keys.second, 32), caps?.let { PeerCapabilities(it) })
                val enc = a.encode()
                if (nick == "carol") carolEncoded = enc
                val dec = enc?.let { IdentityAnnouncement.decode(it) }
                cases += case(
                    "announce_$nick", "announce_tlv",
                    mapOf("nickname" to nick, "noise_key" to rep(keys.first, 32), "signing_key" to rep(keys.second, 32), "capabilities" to caps),
                    mapOf(
                        "encoded" to enc,
                        "decoded_capabilities_raw" to dec?.capabilities?.rawValue,
                        "decoded_nickname" to dec?.nickname
                    )
                )
            }
            // Insert unknown TLV 0x7f ("abc") between the signing key and the capabilities TLV.
            val ce = carolEncoded!!
            val insertAt = (2 + 5) + (2 + 32) + (2 + 32)
            val unknown = byteArrayOf(0x7f, 0x03) + ascii("abc")
            val withUnknown = ce.copyOfRange(0, insertAt) + unknown + ce.copyOfRange(insertAt, ce.size)
            val dec = IdentityAnnouncement.decode(withUnknown)
            cases += case(
                "announce_carol_with_unknown_tlv_0x7f_in_middle", "announce_tlv",
                mapOf("encoded" to withUnknown),
                mapOf(
                    "decodes" to (dec != null),
                    "nickname" to dec?.nickname,
                    "noise_key" to dec?.noisePublicKey,
                    "signing_key" to dec?.signingPublicKey,
                    "capabilities_raw" to dec?.capabilities?.rawValue,
                    "unknown_tlvs" to dec?.unknownTLVs?.map { mapOf("type" to it.type, "value" to it.value) },
                    "reencoded" to dec?.encode()
                )
            )
            // Unknown TLV with capabilities absent (alice) and appended at the end.
            val ae = IdentityAnnouncement("alice", rep(1, 32), rep(2, 32), null).encode()!!
            val aeWithUnknown = ae + byteArrayOf(0x7f, 0x01, 0x5a)
            val adec = IdentityAnnouncement.decode(aeWithUnknown)
            cases += case(
                "announce_alice_with_unknown_tlv_0x7f_appended", "announce_tlv",
                mapOf("encoded" to aeWithUnknown),
                mapOf(
                    "decodes" to (adec != null),
                    "nickname" to adec?.nickname,
                    "capabilities_raw" to adec?.capabilities?.rawValue,
                    "unknown_tlvs" to adec?.unknownTLVs?.map { mapOf("type" to it.type, "value" to it.value) },
                    "reencoded" to adec?.encode()
                )
            )
        }

        // ---------- capabilities ----------
        for (raw in listOf(0L, 1L, 0x100L, 0x300L, 0x7ffL, 0x10000L)) {
            cases += case("caps_encode_0x%x".format(raw), "capabilities", mapOf("raw" to raw), mapOf("encoded" to PeerCapabilities(raw).encoded()))
        }
        for (encHex in listOf("", "00", "0001", "0003", "ffffffffffffffffff")) {
            val d = PeerCapabilities.decode(unhex(encHex))
            cases += case(
                "caps_decode_" + (if (encHex.isEmpty()) "empty" else encHex), "capabilities",
                mapOf("encoded" to unhex(encHex)),
                mapOf("raw" to d.rawValue, "raw_u64_hex" to "%016x".format(d.rawValue), "reencoded" to d.encoded())
            )
        }

        // ---------- private_message_tlv ----------
        run {
            val pm = listOf("m1" to "hi", "550e8400-e29b-41d4-a716-446655440000" to "a".repeat(255), "m3" to "a".repeat(256))
            for ((id, content) in pm) {
                val enc = PrivateMessagePacket(id, content).encode()
                val dec = enc?.let { PrivateMessagePacket.decode(it) }
                cases += case(
                    "pm_${id}_content_${content.length}", "private_message_tlv",
                    mapOf("message_id" to id, "content" to content),
                    mapOf("encoded" to enc, "decodes" to (dec != null), "decoded_message_id" to dec?.messageID, "decoded_content_len" to dec?.content?.length)
                )
            }
            val base = PrivateMessagePacket("m1", "hi").encode()!!
            val withExtra = base + byteArrayOf(0x04, 0x01, 0x78)
            val dec = PrivateMessagePacket.decode(withExtra)
            cases += case(
                "pm_m1_hi_with_unknown_tlv_0x04_appended", "private_message_tlv",
                mapOf("encoded" to withExtra),
                mapOf("decodes" to (dec != null), "decoded_message_id" to dec?.messageID, "decoded_content" to dec?.content)
            )
        }

        // ---------- noise_payload ----------
        run {
            val enc = NoisePayload(NoisePayloadType.PRIVATE_MESSAGE, unhex("0001")).encode()
            cases += case("noise_private_message_0001", "noise_payload", mapOf("type" to 0x01, "data" to unhex("0001")), mapOf("encoded" to enc))
            val dec09 = NoisePayload.decode(unhex("09aabb"))
            cases += case(
                "noise_decode_type_0x09_prerelease_alias", "noise_payload",
                mapOf("encoded" to unhex("09aabb")),
                mapOf("decodes" to (dec09 != null), "type_name" to dec09?.type?.name, "type_value" to dec09?.type?.value?.toInt(), "data" to dec09?.data, "reencoded" to dec09?.encode())
            )
            for (t in listOf(0x20, 0x21, 0x08, 0x00, 0x07, 0xff)) {
                val d = NoisePayload.decode(byteArrayOf(t.toByte(), 0x01))
                cases += case(
                    "noise_decode_type_0x%02x".format(t), "noise_payload",
                    mapOf("encoded" to byteArrayOf(t.toByte(), 0x01)),
                    mapOf("decodes" to (d != null), "type_name" to d?.type?.name, "type_value" to d?.type?.value?.toInt())
                )
            }
        }

        // ---------- file_packet_tlv ----------
        run {
            val f1 = BitchatFilePacket("a.txt", 2, "text/plain", ascii("hi"))
            val f2 = BitchatFilePacket("sample.jpg", 4096, "image/jpeg", ByteArray(4096) { (it % 251).toByte() })
            for ((n, f) in listOf("file_a_txt" to f1, "file_sample_jpg" to f2)) {
                val enc = f.encode()
                val dec = enc?.let { BitchatFilePacket.decode(it) }
                cases += case(
                    n, "file_packet_tlv",
                    mapOf("file_name" to f.fileName, "file_size" to f.fileSize, "mime_type" to f.mimeType, "content" to f.content),
                    mapOf("encoded" to enc, "decodes" to (dec != null), "decoded_file_size" to dec?.fileSize, "decoded_content_matches" to dec?.content?.contentEquals(f.content))
                )
            }
            val e1 = f1.encode()!!
            // name TLV (1+2+5) + size TLV (1+2+4) + mime TLV (1+2+10) = 28 -> insert before CONTENT
            val insertAt = (1 + 2 + 5) + (1 + 2 + 4) + (1 + 2 + 10)
            val unk = byteArrayOf(0x05, 0x00, 0x0b) + ascii("media-mid-1")
            val withUnknown = e1.copyOfRange(0, insertAt) + unk + e1.copyOfRange(insertAt, e1.size)
            val dec = BitchatFilePacket.decode(withUnknown)
            cases += case(
                "file_a_txt_with_unknown_tlv_0x05_before_content", "file_packet_tlv",
                mapOf("encoded" to withUnknown),
                mapOf(
                    "decodes" to (dec != null),
                    "file_name" to dec?.fileName, "file_size" to dec?.fileSize, "mime_type" to dec?.mimeType, "content" to dec?.content,
                    "reencoded" to dec?.encode()
                )
            )
            val withUnknownAtEnd = e1 + unk
            val dec2 = BitchatFilePacket.decode(withUnknownAtEnd)
            cases += case(
                "file_a_txt_with_unknown_tlv_0x05_appended", "file_packet_tlv",
                mapOf("encoded" to withUnknownAtEnd),
                mapOf("decodes" to (dec2 != null), "file_name" to dec2?.fileName, "file_size" to dec2?.fileSize, "mime_type" to dec2?.mimeType, "content" to dec2?.content)
            )
        }

        // ---------- fragment_payload ----------
        run {
            val fid = ByteArray(8) { (0x0a + it).toByte() }
            val fp = FragmentPayload(fid, 1, 3, 0x22u, unhex("010203"))
            val enc = fp.encode()
            val dec = FragmentPayload.decode(enc)
            cases += case(
                "fragment_1_of_3_type_0x22", "fragment_payload",
                mapOf("fragment_id" to fid, "index" to 1, "total" to 3, "original_type" to 0x22, "data" to unhex("010203")),
                mapOf("encoded" to enc, "decodes" to (dec != null), "decoded_index" to dec?.index, "decoded_total" to dec?.total)
            )
        }

        // ---------- peer_id ----------
        for ((n, k) in listOf("key_32x01" to rep(1, 32), "key_32xff" to rep(0xff, 32), "key_0_to_31" to ByteArray(32) { it.toByte() }, "key_31_bytes_invalid" to rep(1, 31))) {
            cases += case(n, "peer_id", mapOf("noise_static_pubkey" to k), mapOf("peer_id" to NoisePeerIdentity.derivePeerID(k)))
        }

        // ---------- write ----------
        val root = mapOf(
            "source" to "permissionlesstech/bitchat-android@dfc67dad",
            "generator" to "Approach A: JUnit test SonarVectorDumpTest.kt run inside the upstream Gradle unit-test harness (JVM, android.util.Log stubbed by app/src/test/kotlin/android/util/Log.kt); every expected value is the real upstream Kotlin codec output. Compression = java.util.zip.Deflater(DEFAULT_COMPRESSION, nowrap=true), JDK 17 (JBR 17.0.12). signing_preimage = BitchatPacket.toBinaryDataForSigning() which upstream encodes WITH padding and TTL=0.",
            "cases" to cases
        )
        val sb = StringBuilder()
        json(root, sb, 0)
        sb.append("\n")
        val out = File(outPath)
        out.parentFile.mkdirs()
        out.writeText(sb.toString())
        println("SONAR_VECTORS_WRITTEN ${out.absolutePath} cases=${cases.size}")
    }
}
