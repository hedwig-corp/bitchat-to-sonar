package chat.bitchat.sonar.ui

import androidx.compose.runtime.Composable

/**
 * Live camera QR scanner for the send-payment picker (design pay.jsx
 * `ScanQrSheet`). Fills the space it is given; [onCode] fires once per decoded
 * payload — the caller is responsible for stopping the scan afterwards.
 *
 * [onUnavailable] is invoked when this platform cannot scan at all (no camera,
 * or permission refused), so the sheet can fall back to "type the code
 * instead" rather than showing a dead viewfinder.
 */
@Composable
expect fun SonarQrScanner(
    onCode: (String) -> Unit,
    onUnavailable: (String) -> Unit,
)

/** Whether this platform can offer camera scanning at all (gates the row). */
expect fun sonarQrScanSupported(): Boolean
