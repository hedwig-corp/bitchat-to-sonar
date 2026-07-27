package chat.bitchat.sonar.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect

/**
 * Desktop has no camera pipeline (CameraX is Android-only and there is no
 * cross-platform JVM webcam stack we ship), so scanning is unavailable here and
 * [sonarQrScanSupported] returns false — the send-payment picker hides the
 * "Scan a QR code" row on desktop rather than offering a dead viewfinder.
 * Pasting a Bolt12 offer, a Lightning invoice or an address into the field
 * reaches every destination the scanner would.
 */
@Composable
actual fun SonarQrScanner(
    onCode: (String) -> Unit,
    onUnavailable: (String) -> Unit,
) {
    LaunchedEffect(Unit) {
        onUnavailable("Scanning isn't available on desktop — paste the code instead.")
    }
}

actual fun sonarQrScanSupported(): Boolean = false
