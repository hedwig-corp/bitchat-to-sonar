package chat.bitchat.sonar

import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

/**
 * Android `actual`: last-known GPS → geohash channels at each level, with names
 * from the platform reverse-geocoder. Best-effort: any missing piece just drops
 * that level (the Mesh channel is added by the caller).
 */
actual object LocationChannels {
    private val ctx: Context get() = AppContextHolder.ctx

    private fun hasLocationPerm(): Boolean =
        ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
        ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    // Mobile resolves location from GPS — no IP opt-in needed, so the desktop
    // Settings toggle is hidden here.
    actual fun configurable(): Boolean = false

    actual suspend fun current(): List<GeoChannel> = withContext(Dispatchers.IO) {
        if (!hasLocationPerm()) return@withContext emptyList()
        val loc = lastKnown() ?: return@withContext emptyList()
        val address = runCatching { reverseGeocode(loc) }.getOrNull()

        val out = ArrayList<GeoChannel>()
        var lastName: String? = null
        for (level in GeoLevel.entries) {
            val gh = Geohash.encode(loc.latitude, loc.longitude, level.length)
            val name = nameFor(level, address) ?: continue
            if (name == lastName) continue // skip consecutive duplicates (same place at finer zoom)
            lastName = name
            out.add(GeoChannel(gh, name, level))
        }
        out
    }

    private fun lastKnown(): Location? {
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        return try {
            val providers = lm.getProviders(true)
            providers.mapNotNull { @Suppress("MissingPermission") lm.getLastKnownLocation(it) }
                .maxByOrNull { it.time }
        } catch (_: SecurityException) { null }
    }

    @Suppress("DEPRECATION")
    private fun reverseGeocode(loc: Location): android.location.Address? {
        if (!Geocoder.isPresent()) return null
        val geo = Geocoder(ctx, Locale.getDefault())
        // Use the blocking API (we are already on Dispatchers.IO). The async API
        // (33+) would need a callback bridge; the sync call is fine off-main.
        return geo.getFromLocation(loc.latitude, loc.longitude, 1)?.firstOrNull()
    }

    private fun nameFor(level: GeoLevel, a: android.location.Address?): String? {
        if (a == null) return null
        return when (level) {
            GeoLevel.Building -> a.featureName?.takeUnless { it == a.thoroughfare } ?: a.subThoroughfare ?: a.subLocality
            GeoLevel.Block -> a.thoroughfare ?: a.subLocality
            GeoLevel.Neighborhood -> a.subLocality ?: a.subAdminArea
            GeoLevel.City -> a.locality ?: a.subAdminArea
            GeoLevel.Province -> a.adminArea
            GeoLevel.Region -> a.countryName
        }?.takeIf { it.isNotBlank() }
    }
}
