package chat.bitchat.sonar

/**
 * Resolves the device's current location into the geohash channels shown on the
 * home (Ottaviano → Italy), mirroring the iOS LocationChannelManager. Needs the
 * location permission; returns empty when unavailable (so the home just shows
 * the Mesh channel).
 */
expect object LocationChannels {
    /** Geohash channels for the current GPS position, building → region. */
    suspend fun current(): List<GeoChannel>
}
