package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BluetoothAdapterLifecycleTest {
    @Test
    fun adapterTurningOffSuspendsRadioAndDemotesRoute() {
        assertEquals(
            BleRadioLifecycleAction.Suspend,
            bleRadioLifecycleAction(BleAdapterLifecycleState.TurningOff, radioRequested = true),
        )
        // Android may not deliver the GATT disconnect until later. Adapter state
        // must win immediately so the caller can choose White Noise instead.
        assertFalse(meshRouteAvailable(radioUsable = false, gattLinked = true))
    }

    @Test
    fun adapterOffSuspendsEvenWhenRadioWasNotRequested() {
        assertEquals(
            BleRadioLifecycleAction.Suspend,
            bleRadioLifecycleAction(BleAdapterLifecycleState.Off, radioRequested = false),
        )
    }

    @Test
    fun adapterOnResumesOnlyARequestedRadio() {
        assertEquals(
            BleRadioLifecycleAction.Resume,
            bleRadioLifecycleAction(BleAdapterLifecycleState.On, radioRequested = true),
        )
        assertEquals(
            BleRadioLifecycleAction.Ignore,
            bleRadioLifecycleAction(BleAdapterLifecycleState.On, radioRequested = false),
        )
    }

    @Test
    fun adapterTurningOnWaitsForUsableOnState() {
        assertEquals(
            BleRadioLifecycleAction.Ignore,
            bleRadioLifecycleAction(BleAdapterLifecycleState.TurningOn, radioRequested = true),
        )
    }

    @Test
    fun meshRouteRequiresBothUsableAdapterAndLiveGattLink() {
        assertTrue(meshRouteAvailable(radioUsable = true, gattLinked = true))
        assertFalse(meshRouteAvailable(radioUsable = true, gattLinked = false))
        assertFalse(meshRouteAvailable(radioUsable = false, gattLinked = true))
        assertFalse(meshRouteAvailable(radioUsable = false, gattLinked = false))
    }
}
