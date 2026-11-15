package chat.bitchat.sonar

/** Another bitchat-protocol app that can be installed beside Sonar. */
data class OtherMeshApp(val packageName: String, val name: String)

/**
 * Other mesh apps installed on this device. Two apps on one phone share its
 * Bluetooth radio and register the same mesh service UUID: nearby devices
 * then reach only one of them per connection, and the app that loses never
 * shows up. Sonar cannot tell whether the other app is running, only whether
 * it is installed.
 *
 * Android only. The iOS app cannot detect stock bitchat: Sonar iOS registers
 * the `bitchat://` URL scheme itself, so `canOpenURL` cannot tell the two
 * apart. Detection there needs Sonar to drop that scheme, or a scheme only
 * stock bitchat registers (QA-191).
 */
expect object OtherMeshApps {
    /** A cross-process lookup on Android: call on start and foreground, never per frame. */
    fun installed(): List<OtherMeshApp>

    /** Open the system page where the user can force-stop [app]. */
    fun openSettings(app: OtherMeshApp)
}

/** The apps Sonar knows to clash with it on the radio. */
internal val KNOWN_OTHER_MESH_APPS = listOf(
    OtherMeshApp(packageName = "com.bitchat.droid", name = "bitchat"),
)
