package chat.bitchat.sonar

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * Desktop (JVM) `actual`: a desktop has no GPS sensor, so location channels are
 * resolved — only when the user explicitly opts in — from the device's public IP
 * via a geolocation service over HTTPS. Off by default; the opt-in lives in
 * Settings → "Approximate location (IP)".
 *
 * Privacy note: when enabled, this sends the device's IP to a third-party
 * geolocation endpoint (ipapi.co). It is therefore opt-in, coarse (city / region
 * / country only — IP can't resolve street-level), and never on without consent.
 * The geohash channels themselves are relay-backed and identical to mobile, so
 * messages + "N here now" presence interop with the phone apps.
 */
actual object LocationChannels {
    /** Pref key written by SonarAppState.setPref("ipLocation", …): blobs are
     *  stored under "blob.pref.<key>" with "1"/"0" values. */
    private const val PREF_KEY = "blob.pref.ipLocation"
    // The poll loop re-calls current() every tick while the list is empty; don't
    // re-hit the geolocation endpoint more than once a minute (offline / rate-limit).
    private const val RETRY_THROTTLE_MS = 60_000L

    /** Keyless geolocation providers, tried in order until one yields coordinates.
     *  HTTPS first (no location leaked in cleartext); the HTTP ip-api.com is a
     *  last-resort fallback (its free tier has no HTTPS). Field names differ per
     *  provider, so each carries its own key mapping. */
    private data class Provider(
        val url: String,
        val latKey: String, val lonKey: String,
        val cityKey: String, val regionKey: String, val countryKey: String,
    )

    private val PROVIDERS = listOf(
        Provider("https://ipwho.is/", "latitude", "longitude", "city", "region", "country"),
        Provider("https://get.geojs.io/v1/ip/geo.json", "latitude", "longitude", "city", "region", "country"),
        Provider(
            "http://ip-api.com/json/?fields=status,lat,lon,city,regionName,country",
            "lat", "lon", "city", "regionName", "country",
        ),
    )

    @Volatile private var cached: List<GeoChannel>? = null
    @Volatile private var lastAttemptMs: Long = 0

    actual fun configurable(): Boolean = true

    private fun optedIn(): Boolean = DesktopEnv.getString(PREF_KEY, "") == "1"

    actual suspend fun current(): List<GeoChannel> = withContext(Dispatchers.IO) {
        if (!optedIn()) { cached = null; lastAttemptMs = 0; return@withContext emptyList() }
        cached?.let { return@withContext it }
        val now = System.currentTimeMillis()
        if (now - lastAttemptMs < RETRY_THROTTLE_MS) return@withContext emptyList()
        lastAttemptMs = now
        val channels = runCatching { fetch() }.getOrNull().orEmpty()
        if (channels.isNotEmpty()) cached = channels
        channels
    }

    private fun fetch(): List<GeoChannel> {
        for (p in PROVIDERS) {
            val body = httpGet(p.url) ?: continue
            val lat = numField(body, p.latKey) ?: continue
            val lon = numField(body, p.lonKey) ?: continue
            // IP gives coarse location only — city (5) / province (4) / region (2),
            // fine → coarse, mirroring the home list order. Skip blanks and collapse
            // consecutive duplicate names (same place at a coarser zoom).
            val levels = listOf(
                GeoLevel.City to strField(body, p.cityKey),
                GeoLevel.Province to strField(body, p.regionKey),
                GeoLevel.Region to strField(body, p.countryKey),
            )
            val out = ArrayList<GeoChannel>()
            var lastName: String? = null
            for ((level, name) in levels) {
                if (name.isNullOrBlank() || name == lastName) continue
                lastName = name
                out.add(GeoChannel(Geohash.encode(lat, lon, level.length), name, level))
            }
            if (out.isNotEmpty()) return out
        }
        return emptyList()
    }

    private fun httpGet(url: String): String? {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 5_000
            readTimeout = 5_000
            setRequestProperty("Accept", "application/json")
            setRequestProperty("User-Agent", "Sonar-Desktop")
        }
        return try {
            if (conn.responseCode != 200) return null
            conn.inputStream.bufferedReader().use { it.readText() }
        } catch (_: Throwable) {
            null
        } finally {
            conn.disconnect()
        }
    }

    // Minimal field extraction — no JSON dependency on the desktop classpath.
    private fun strField(json: String, key: String): String? =
        Regex("\"" + key + "\"\\s*:\\s*\"([^\"]*)\"").find(json)?.groupValues?.get(1)

    // Accepts both bare (47.3) and string-quoted ("47.3") numbers — providers differ.
    private fun numField(json: String, key: String): Double? =
        Regex("\"" + key + "\"\\s*:\\s*\"?(-?[0-9]+\\.?[0-9]*)\"?").find(json)?.groupValues?.get(1)?.toDoubleOrNull()
}
