package chat.bitchat.sonar

/**
 * Geohash encoder (standard base-32) — turns a GPS coordinate into the geohash
 * strings used as Nostr location-channel ids, at the precision levels the iOS
 * app shows on the home (building → region).
 */
object Geohash {
    private const val BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"

    fun encode(lat: Double, lon: Double, length: Int): String {
        var latMin = -90.0; var latMax = 90.0
        var lonMin = -180.0; var lonMax = 180.0
        val sb = StringBuilder()
        var bit = 0
        var ch = 0
        var even = true
        while (sb.length < length) {
            if (even) {
                val mid = (lonMin + lonMax) / 2
                if (lon >= mid) { ch = (ch shl 1) or 1; lonMin = mid } else { ch = ch shl 1; lonMax = mid }
            } else {
                val mid = (latMin + latMax) / 2
                if (lat >= mid) { ch = (ch shl 1) or 1; latMin = mid } else { ch = ch shl 1; latMax = mid }
            }
            even = !even
            if (bit < 4) { bit++ } else { sb.append(BASE32[ch]); bit = 0; ch = 0 }
        }
        return sb.toString()
    }
}

/** A location channel level + the geohash precision it maps to (matches iOS). */
enum class GeoLevel(val label: String, val length: Int) {
    Building("building", 8),
    Block("block", 7),
    Neighborhood("neighborhood", 6),
    City("city", 5),
    Province("province", 4),
    Region("region", 3),
}

/** A discovered location channel for the home list. */
data class GeoChannel(
    val geohash: String,
    val name: String,
    val level: GeoLevel,
)
