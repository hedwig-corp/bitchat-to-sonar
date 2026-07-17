package chat.bitchat.sonar.baselineprofile

import android.util.Log
import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

private const val PKG = "chat.bitchat.sonar"
private const val SEEDED_CHAT = "Sonar agent DM"
private const val TAG = "BaselineProfileGen"

/**
 * Generates the Baseline Profile shipped inside the release APK
 * (`composeApp/src/androidRelease/generated/baselineProfiles/`).
 *
 * Profiled journeys, matching the issue #305 pain points:
 *  1. cold start to the chat list (with an onboarded account when a key is
 *     provided — the realistic cold start);
 *  2. open a conversation containing text + image messages and scroll it
 *     (the first-composition frame this profile exists to speed up).
 *
 * Journey 2 needs an account whose relays already hold a seeded DM named
 * "Sonar agent DM" (seed one with `sonar-cli send`, see docs/PERFORMANCE.md).
 * Pass the account key via an instrumentation argument so nothing is
 * committed; onboarding restore runs ONCE before profiling starts:
 *
 * ```
 * ./gradlew :baselineprofile:generateBaselineProfile \
 *   -Pandroid.testInstrumentationRunnerArguments.sonarBenchNsec=nsec1...
 * ```
 *
 * Without the argument the generator produces a valid profile from the
 * cold-start/onboarding journey only and logs that the chat-open journey was
 * skipped (a weaker profile, not a failure).
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class BaselineProfileGenerator {

    @get:Rule
    val rule = BaselineProfileRule()

    @Test
    fun generate() {
        val nsec = InstrumentationRegistry.getArguments().getString("sonarBenchNsec")
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

        // One-time setup outside the profiled block: restore the bench account
        // and wait for the seeded conversation to sync in from relays.
        val chatReady = if (!nsec.isNullOrBlank()) {
            prepareAccount(device, nsec)
        } else {
            Log.i(TAG, "sonarBenchNsec not set: profiling cold start + onboarding only")
            false
        }

        rule.collect(
            packageName = PKG,
            maxIterations = 8,
            includeInStartupProfile = true,
        ) {
            // A tracked cold launch each iteration: the rule can only harvest
            // profiles from processes it launched and killed itself
            // ("never flushed profiles" otherwise).
            killProcess()
            pressHome()
            startActivityAndWait()
            device.waitForIdle()

            if (!chatReady) {
                // Fresh-install path: exercise the onboarding pager instead.
                device.clickIfPresent(By.text("Get started"), 5_000)
                device.clickIfPresent(By.text("Continue"), 5_000)
                return@collect
            }

            // Open the seeded transcript (text + images) — the first-composition
            // frame profiled here is the issue #305 jank.
            val row = device.wait(Until.findObject(By.text(SEEDED_CHAT)), 15_000)
            if (row == null) {
                Log.i(TAG, "Seeded chat not on screen this iteration; startup only")
                return@collect
            }
            row.click()
            device.waitForIdle()
            Thread.sleep(2_000)

            // Scroll the transcript: up into history, back down to the tail.
            device.findObject(By.scrollable(true))?.let { list ->
                repeat(3) { list.scroll(Direction.UP, 0.8f); device.waitForIdle() }
                repeat(3) { list.scroll(Direction.DOWN, 0.8f); device.waitForIdle() }
            }
            device.pressBack()
            device.waitForIdle()
        }
    }
}

/**
 * Ensure the app holds the bench account with the seeded DM synced, restoring
 * through onboarding if needed. Returns true when the chat row is visible.
 */
private fun prepareAccount(device: UiDevice, nsec: String): Boolean {
    grantRuntimePermissions(device)
    device.executeShellCommand(
        "am start -W -n $PKG/.MainActivity"
    )
    device.waitForIdle()
    dismissPermissionDialogs(device)

    // Already onboarded with the seeded chat visible? Done.
    if (device.wait(Until.hasObject(By.text(SEEDED_CHAT)), 5_000)) {
        Log.i(TAG, "seeded chat already present; skipping restore")
        device.pressHome()
        return true
    }

    // Fresh install: drive onboarding's "Restore account" path. Compose puts
    // the click handler on a parent of the text node, so By.clickable(true)
    // never matches — click the text node's bounds instead. The restore screen
    // ALSO titles itself "Restore account"; clicking the BOTTOM-most match
    // picks the footer link / submit button, never the title.
    if (device.clickBottomMatch("Restore account", 10_000)) {
        Log.i(TAG, "onboarding intro reached; opening restore")
        val field = device.wait(Until.findObject(By.clazz("android.widget.EditText")), 5_000)
        if (field == null) {
            Log.i(TAG, "nsec field not found; skipping restore")
            return false
        }
        field.click()
        field.text = nsec
        device.waitForIdle()
        Thread.sleep(1_000) // let the submit button enable on the validated key
        if (!device.clickBottomMatch("Restore account", 5_000)) {
            Log.i(TAG, "restore submit button not found; skipping restore")
            return false
        }
        if (device.wait(Until.hasObject(By.textContains("MESSAGES")), 60_000) != true) {
            Log.i(TAG, "chat list never appeared after restore")
        } else {
            Log.i(TAG, "restore complete; waiting for the seeded conversation")
        }
    } else {
        Log.i(TAG, "onboarding intro not found; screen shows: " + device.visibleTexts())
    }

    // The seeded conversation syncs in from relays in the background; give the
    // image rows time to land too before profiling opens against it.
    val ready = device.wait(Until.hasObject(By.text(SEEDED_CHAT)), 180_000) == true
    if (ready) Thread.sleep(10_000) else Log.i(TAG, "Seeded chat never appeared; profile covers startup only")
    device.pressHome()
    return ready
}

/** System permission prompts steal the foreground from the first launch when
 *  a `pm grant` did not cover something; approve them so onboarding is
 *  reachable. */
private fun dismissPermissionDialogs(device: UiDevice) {
    repeat(5) {
        val allow = device.findObject(By.text("While using the app"))
            ?: device.findObject(By.text("Allow"))
            ?: return
        allow.click()
        device.waitForIdle()
    }
}

/** Grant everything the first-run flow asks for so system dialogs never
 *  interleave with the profiled journey. Failures are fine (e.g. permissions
 *  that don't exist on this API level). */
private fun grantRuntimePermissions(device: UiDevice) {
    listOf(
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.ACCESS_FINE_LOCATION",
        "android.permission.ACCESS_COARSE_LOCATION",
        "android.permission.RECORD_AUDIO",
        "android.permission.BLUETOOTH_SCAN",
        "android.permission.BLUETOOTH_CONNECT",
        "android.permission.BLUETOOTH_ADVERTISE",
    ).forEach { perm ->
        runCatching { device.executeShellCommand("pm grant $PKG $perm") }
    }
}

private fun UiDevice.clickIfPresent(selector: BySelector, timeoutMs: Long): Boolean {
    val obj = wait(Until.findObject(selector), timeoutMs) ?: return false
    obj.click()
    waitForIdle()
    return true
}

/** Click the bottom-most node whose text equals [text] (by bounds, so it works
 *  when the Compose click handler lives on a parent node). */
private fun UiDevice.clickBottomMatch(text: String, timeoutMs: Long): Boolean {
    if (wait(Until.hasObject(By.text(text)), timeoutMs) != true) return false
    val target = findObjects(By.text(text)).maxByOrNull { it.visibleBounds.bottom } ?: return false
    val b = target.visibleBounds
    click(b.centerX(), b.centerY())
    waitForIdle()
    return true
}

/** The visible text nodes, for failure diagnostics in the test log. */
private fun UiDevice.visibleTexts(): String =
    findObjects(By.textContains("")).mapNotNull { it.text }.take(12).toString()
