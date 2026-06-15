package chat.bitchat.sonar

/**
 * Desktop (JVM) `actual`: no platform geolocation, so no GPS-derived location
 * channels. Returns empty — the home then shows just the Mesh channel + secure
 * chats, exactly like a mobile device with the location permission denied. (A
 * future enhancement could let the user pin a geohash manually.)
 */
actual object LocationChannels {
    actual suspend fun current(): List<GeoChannel> = emptyList()
}
