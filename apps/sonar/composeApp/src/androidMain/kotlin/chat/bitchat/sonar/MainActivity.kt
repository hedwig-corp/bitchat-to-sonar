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

    /** Every runtime permission the app needs, requested together so Android
     *  shows them in one sequence (firing three separate launchers in onCreate
     *  raced and some grants were silently dropped). */
    private val requiredPermissions: Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_ADVERTISE)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
        add(Manifest.permission.RECORD_AUDIO) // voice notes
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }.toTypedArray()

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // Whatever the user granted, (re)try starting the mesh radio.
            startMeshRadio()
        }

    private fun startMeshRadio() {
        MeshRadio.setMeshNickname(SonarCore.nickname())
        MeshRadio.start()
    }

    /** Request any not-yet-granted permission in a single dialog sequence. */
    private fun requestAllPermissions() {
        val missing = requiredPermissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) startMeshRadio() else permissionLauncher.launch(missing.toTypedArray())
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
        requestAllPermissions()
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
