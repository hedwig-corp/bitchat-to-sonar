package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.RelayBenchmarkResult
import chat.bitchat.sonar.RelaySyncSnapshot
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.bestRttMs
import chat.bitchat.sonar.displayRelayHost
import chat.bitchat.sonar.formatBenchmarkSummary
import chat.bitchat.sonar.formatWatermark
import chat.bitchat.sonar.mergeBenchmarkResult
import chat.bitchat.sonar.parseSyncStateSnapshot
import chat.bitchat.sonar.relayUrlsForBenchmark
import chat.bitchat.sonar.runRelayBenchmarks
import chat.bitchat.sonar.ui.SNGhostButton
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.sonar
import kotlinx.coroutines.launch

/**
 * Connection → Internet drill-in: live Marmot/core relay status + one-tap
 * REQ→EOSE latency benchmark. Free of message content / key material.
 *
 * Parity with iOS `SNRelayStatusSheetContent`.
 */
@Composable
fun SonarRelayStatusSheetContent(
    online: Boolean,
    onClose: () -> Unit,
) {
    val s = sonar
    val scope = rememberCoroutineScope()
    var snapshot by remember { mutableStateOf<RelaySyncSnapshot?>(null) }
    var snapshotLoaded by remember { mutableStateOf(false) }
    var benchmarking by remember { mutableStateOf(false) }
    var lastBenchSummary by remember { mutableStateOf<String?>(null) }
    var probes by remember { mutableStateOf<Map<String, RelayBenchmarkResult>>(emptyMap()) }

    suspend fun refreshSnapshot() {
        val json = SonarCore.syncStateSnapshotJson()
        snapshot = parseSyncStateSnapshot(json)
        snapshotLoaded = true
    }

    LaunchedEffect(Unit) {
        refreshSnapshot()
    }

    val relays = snapshot?.relays.orEmpty()
    val connected = relays.count { it.status.equals("connected", ignoreCase = true) }
    val total = relays.size
    val best = bestRttMs(probes.values)

    Column(
        Modifier
            .fillMaxWidth()
            .height(520.dp)
            .verticalScroll(rememberScrollState())
            .padding(bottom = 8.dp),
    ) {
        // ── Summary card ────────────────────────────────────────────────
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(s.surface2)
                .padding(horizontal = 15.dp, vertical = 13.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(if (online) s.green else s.danger),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    if (online) "Internet path up" else "Internet path down",
                    color = s.text,
                    fontSize = 14.5.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (total > 0) "$connected/$total relays" else if (online) "Online" else "Offline",
                    color = s.text3,
                    fontSize = 12.sp,
                    maxLines = 1,
                )
            }
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MetricChip(
                    title = "Relays",
                    value = if (total > 0) "$connected/$total" else "—",
                    modifier = Modifier.weight(1f),
                )
                MetricChip(
                    title = "Best RTT",
                    value = best?.let { "$it ms" } ?: "—",
                    modifier = Modifier.weight(1f),
                )
                MetricChip(
                    title = "Marmot",
                    value = when {
                        snapshot?.liveMarmotEnabled == true -> "live"
                        snapshotLoaded -> "idle"
                        else -> "…"
                    },
                    modifier = Modifier.weight(1f),
                )
            }
            if (lastBenchSummary != null) {
                Spacer(Modifier.height(8.dp))
                Text(lastBenchSummary!!, color = s.text3, fontSize = 12.sp)
            }
            Spacer(Modifier.height(10.dp))
            // Progress bar: connected / total (or full when online with no snapshot).
            val fraction = when {
                total > 0 -> connected.toFloat() / total.toFloat()
                online -> 1f
                else -> 0f
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(5.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(s.surface),
            ) {
                Box(
                    Modifier
                        .fillMaxWidth(fraction.coerceIn(0.02f, 1f))
                        .height(5.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(if (online) s.green else s.accent),
                )
            }
        }

        Spacer(Modifier.height(10.dp))

        // ── Secure chat relays (Marmot/core snapshot) ───────────────────
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(s.surface2)
                .padding(horizontal = 15.dp, vertical = 13.dp),
        ) {
            Text("Secure chat relays", color = s.text2, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            val detail = snapshot?.let { snap ->
                if (snap.liveMarmotEnabled) {
                    "live · ${snap.subscribedGroupCount} chats · sync ${formatWatermark(snap.watermarkSecs)}"
                } else {
                    "sync ${formatWatermark(snap.watermarkSecs)}"
                }
            } ?: if (snapshotLoaded) "not connected" else "loading…"
            Text(detail, color = s.text3, fontSize = 11.5.sp, maxLines = 2)
            Spacer(Modifier.height(8.dp))

            if (relays.isNotEmpty()) {
                relays.forEachIndexed { index, relay ->
                    val connectedRow = relay.status.equals("connected", ignoreCase = true)
                    val probe = probes.entries.firstOrNull { chat.bitchat.sonar.hostsMatch(it.key, relay.url) }?.value
                    RelayRow(
                        url = relay.url,
                        status = relay.status.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() },
                        connected = connectedRow,
                        rttMs = probe?.rttMs,
                        error = probe?.error,
                        divider = index < relays.lastIndex,
                    )
                }
            } else {
                // When snapshot empty, still show the URLs we would measure so the
                // user can run the benchmark without waiting for a live chat.
                val fallback = relayUrlsForBenchmark(snapshot)
                if (snapshotLoaded && fallback.isNotEmpty()) {
                    Text(
                        "Secure chat relays not connected yet — defaults available for probe",
                        color = s.text3,
                        fontSize = 13.sp,
                    )
                    Spacer(Modifier.height(6.dp))
                    fallback.forEachIndexed { index, url ->
                        val probe = probes[url] ?: probes.entries.firstOrNull {
                            chat.bitchat.sonar.hostsMatch(it.key, url)
                        }?.value
                        RelayRow(
                            url = url,
                            status = probe?.let { if (it.success) "Probed" else "Failed" } ?: "Unknown",
                            connected = probe?.success == true,
                            rttMs = probe?.rttMs,
                            error = probe?.error,
                            divider = index < fallback.lastIndex,
                        )
                    }
                } else {
                    Text(
                        if (snapshotLoaded) "Secure chat relays not connected yet" else "Loading…",
                        color = s.text3,
                        fontSize = 13.sp,
                    )
                }
            }
        }

        Spacer(Modifier.height(12.dp))

        // ── Actions ─────────────────────────────────────────────────────
        Column(Modifier.padding(horizontal = 8.dp)) {
            SNPrimaryButton(
                label = if (benchmarking) "Measuring…" else "Run relay benchmark",
                disabled = benchmarking,
            ) {
                if (benchmarking) return@SNPrimaryButton
                benchmarking = true
                lastBenchSummary = "Measuring…"
                scope.launch {
                    refreshSnapshot()
                    val results = runRelayBenchmarks(snapshot = snapshot)
                    var map = probes
                    for (r in results) {
                        map = mergeBenchmarkResult(map, r)
                    }
                    probes = map
                    refreshSnapshot()
                    lastBenchSummary = formatBenchmarkSummary(results)
                    benchmarking = false
                }
            }
            Spacer(Modifier.height(6.dp))
            SNGhostButton("Done", onClick = onClose)
        }
    }
}

@Composable
private fun MetricChip(title: String, value: String, modifier: Modifier = Modifier) {
    val s = sonar
    Column(
        modifier
            .clip(RoundedCornerShape(10.dp))
            .background(s.surface)
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        Text(
            title.uppercase(),
            color = s.text3,
            fontSize = 10.5.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(value, color = s.text, style = SonarType.mono(13.0))
    }
}

@Composable
private fun RelayRow(
    url: String,
    status: String,
    connected: Boolean,
    rttMs: Int?,
    error: String?,
    divider: Boolean,
) {
    val s = sonar
    Column {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(if (connected) s.green else s.danger),
            )
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    displayRelayHost(url),
                    color = s.text,
                    style = SonarType.mono(12.5),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!error.isNullOrBlank() && (rttMs == null || !connected)) {
                    Text(error, color = s.text3, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Spacer(Modifier.width(6.dp))
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    status,
                    color = if (connected) s.green else s.text3,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    rttMs?.let { "$it ms" } ?: "—",
                    color = rttColor(rttMs),
                    style = SonarType.mono(12.0),
                )
            }
        }
        if (divider) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(s.hairline))
        }
    }
}

@Composable
private fun rttColor(ms: Int?): Color {
    val s = sonar
    if (ms == null) return s.text3
    return when {
        ms < 250 -> s.green
        ms < 800 -> s.text2
        else -> s.danger
    }
}
