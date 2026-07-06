package chat.bitchat.sonar

/** Platform-owned audio routing for live calls. */
expect object CallAudioRoute {
    /** [voiceProximity]: hold a proximity screen-off wake lock while a VOICE
     *  call is active (iOS `isProximityMonitoringEnabled` parity) — the screen
     *  blanks at the ear and accidental touches are swallowed. Released when
     *  [active] is false. Video calls never enable it. */
    fun configure(active: Boolean, speakerOn: Boolean, voiceProximity: Boolean = false)
    fun setSpeaker(speakerOn: Boolean)
}
