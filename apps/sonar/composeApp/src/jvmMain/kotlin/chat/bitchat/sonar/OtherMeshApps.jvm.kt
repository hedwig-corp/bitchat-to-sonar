package chat.bitchat.sonar

// Desktop has no package registry to ask, so a co-installed mesh app is not
// detected here (QA-191 lists the gap).
actual object OtherMeshApps {
    actual fun installed(): List<OtherMeshApp> = emptyList()

    actual fun openSettings(app: OtherMeshApp) {}
}
