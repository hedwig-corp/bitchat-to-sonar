package chat.bitchat.sonar

/**
 * Resolves the device's current location into the geohash channels shown on the
 * home (Ottaviano → Italy), mirroring the iOS LocationChannelManager. Needs the
 * location permission; returns empty when unavailable (so the home just shows
 * the Mesh channel).
 */
expect object LocationChannels {
    /** Geohash channels for the current position, fine → coarse. Empty when no
     *  location is available (permission denied on mobile, or — on desktop — the
     *  optional IP-location preference is off). */
    suspend fun current(): List<GeoChannel>

    /** True on platforms where the user can opt into IP-based approximate
     *  location (desktop, which has no GPS). The Settings toggle is hidden when
     *  false — mobile resolves location from GPS, no opt-in needed. */
    fun configurable(): Boolean
}
