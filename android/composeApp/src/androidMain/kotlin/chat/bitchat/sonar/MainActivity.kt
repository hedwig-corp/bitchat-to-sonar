package chat.bitchat.sonar

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts

class MainActivity : ComponentActivity() {

    private val blePermissions: Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            MeshRadio.start()
        }

    private var unlockCb: ((Boolean) -> Unit)? = null
    private val unlockLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            unlockCb?.invoke(res.resultCode == RESULT_OK)
            unlockCb = null
        }

    /** Launch the device-credential (PIN/pattern/biometric) confirm screen. */
    private fun confirmDeviceCredential(onResult: (Boolean) -> Unit) {
        val km = getSystemService(android.app.KeyguardManager::class.java)
        @Suppress("DEPRECATION")
        val intent = km?.createConfirmDeviceCredentialIntent("Unlock Sonar", "Confirm it's you to continue")
        if (intent == null) { onResult(true); return } // no secure lock → nothing to confirm
        unlockCb = onResult
        unlockLauncher.launch(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        ActivityBridge.requestUnlock = { cb -> confirmDeviceCredential(cb) }
        meshNoiseSmokeTest()
        requestMeshPermissions()
        requestNotificationPermission()
        setContent {
            App()
        }
    }

    /**
     * Runtime check that the BLE mesh's Noise XX crypto works through the Rust
     * .so on this device (the unit-tested core, exercised over the JNA FFI):
     * two in-process sessions handshake and exchange an encrypted message.
     */
    private fun meshNoiseSmokeTest() {
        try {
            val a = uniffi.sonar_ffi.noiseGenerateKeypair()
            val b = uniffi.sonar_ffi.noiseGenerateKeypair()
            val ini = uniffi.sonar_ffi.SonarNoise.initiator(a.privateHex)
            val res = uniffi.sonar_ffi.SonarNoise.responder(b.privateHex)
            res.readMessage(ini.writeMessage())   // m1
            ini.readMessage(res.writeMessage())    // m2
            res.readMessage(ini.writeMessage())    // m3
            val peerOk = ini.remoteStaticHex() == b.publicHex && res.remoteStaticHex() == a.publicHex
            ini.intoSession(); res.intoSession()
            val ct = ini.encrypt("mesh hello".encodeToByteArray())
            val pt = res.decrypt(ct).decodeToString()
            android.util.Log.i("MeshNoiseSmoke", "ok=${pt == "mesh hello" && peerOk} decrypted=$pt")
        } catch (t: Throwable) {
            android.util.Log.e("MeshNoiseSmoke", "noise FFI failed", t)
        }
    }

    private fun requestMeshPermissions() {
        val granted = blePermissions.all {
            checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
        if (granted) MeshRadio.start() else permissionLauncher.launch(blePermissions)
    }

    private val notifPermLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    /** Ask for POST_NOTIFICATIONS on Android 13+ (no-op below). */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notifPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onResume() {
        super.onResume()
        SonarLifecycle.onForeground?.invoke(true)
    }

    override fun onPause() {
        super.onPause()
        SonarLifecycle.onForeground?.invoke(false)
    }

    override fun onDestroy() {
        MeshRadio.stop()
        super.onDestroy()
    }
}
