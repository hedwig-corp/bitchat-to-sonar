package chat.bitchat.sonar

/** Platform-owned audio routing for live calls. */
expect object CallAudioRoute {
    fun configure(active: Boolean, speakerOn: Boolean)
    fun setSpeaker(speakerOn: Boolean)
}
