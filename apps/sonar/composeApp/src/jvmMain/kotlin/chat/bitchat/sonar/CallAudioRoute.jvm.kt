package chat.bitchat.sonar

actual object CallAudioRoute {
    actual fun configure(active: Boolean, speakerOn: Boolean, voiceProximity: Boolean) {}
    actual fun setSpeaker(speakerOn: Boolean) {}
}
