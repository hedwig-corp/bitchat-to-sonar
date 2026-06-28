package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ToastBar
import chat.bitchat.sonar.wallet.FiatCurrency
import chat.bitchat.sonar.wallet.WalletState
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SNSettingsCard
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SNTrail
import chat.bitchat.sonar.ui.sonar
import chat.bitchat.sonar.Notifier

/**
 * Full Settings screen — 1:1 reproduction of design/handoff/project/sonar/
 * settings.jsx (Signal/XChat-inspired): profile row, App / Network / Wallet /
 * Privacy & safety / Data & storage / About sections, with the Notifications,
 * App icon and Message-requests sheets. Real backends are bound where they
 * exist; demo-only rows persist their toggle locally.
 */
@Composable
fun SonarSettingsScreen(state: SonarAppState) {
    val s = sonar
    var wipeAsk by remember { mutableStateOf(false) }
    var eraseAsk by remember { mutableStateOf(false) }
    var currencyPick by remember { mutableStateOf(false) }
    var exportKey by remember { mutableStateOf(false) }
    var notif by remember { mutableStateOf(false) }
    var appicon by remember { mutableStateOf(false) }
    var requests by remember { mutableStateOf(false) }
    state.prefsVersion // subscribe so toggles recompose

    val balance = (state.walletState as? WalletState.Ready)?.balanceSats ?: 0L
    val iconLabel = when (state.prefStr("icon", "cyan")) {
        "midnight" -> "Midnight"; "paper" -> "Paper"; else -> "Cyan"
    }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Settings", hairline = false, onBack = { state.back() })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // profile card → Profile
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(20.dp)).background(s.surface)
                    .clickable { state.push(Screen.Profile) }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SonarAvatar(state.nick.ifBlank { "you" }, 56.dp)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(state.nick.ifBlank { "you" }, color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Text(shortKey(state.npub), color = s.text3, fontSize = 12.sp)
                }
                SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
            }

            SNSectionLabel("App")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Moon, label = "Appearance",
                    value = if (state.dark) "Dark" else "Light", trail = SNTrail.None,
                ) { state.toggleDark() }
                SNSettingsRow(
                    icon = SNIconName.Rings, label = "App icon", value = iconLabel,
                ) { appicon = true }
                SNSettingsRow(
                    icon = SNIconName.Info, label = "Notifications",
                    value = if (state.prefBool("notifs", true)) "On" else "Off",
                    divider = false,
                ) { notif = true }
            }

            SNSectionLabel("Network")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Mesh, tone = SNTone.Cyan, label = "Connection",
                    sub = if (state.started) "Bluetooth + internet" else "Nearby only, no internet",
                    value = if (state.started) "Online" else "Bluetooth only",
                    trail = SNTrail.None, divider = false,
                ) {}
            }

            SNSectionLabel("Wallet")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Coin, tone = SNTone.Gold, label = "Bitcoin",
                    sub = "Pays like you message — Bluetooth or Lightning",
                    value = if (state.walletAvailable) "${formatThousands(balance)} sats" else "Off",
                    trail = SNTrail.None,
                ) { if (state.walletAvailable) state.push(Screen.WalletActivity) }
                if (state.walletAvailable) {
                    SNSettingsRow(
                        icon = SNIconName.Coin, label = "Currency", value = state.currency.code,
                    ) { currencyPick = true }
                    SNSettingsRow(
                        icon = SNIconName.Bolt, label = "Show balance in fiat",
                        toggle = state.showFiat, trail = SNTrail.None, divider = false,
                    ) { state.toggleShowFiat() }
                }
            }

            SNSectionLabel("Privacy & safety")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Lock, label = "App lock",
                    sub = "Require your device unlock to open Sonar",
                    toggle = state.appLockOn,
                ) {
                    if (state.appLockAvailable) state.setAppLock(!state.appLockOn)
                    else state.toast = "Set a screen lock on your device first"
                }
                SNSettingsRow(
                    icon = SNIconName.Key, tone = SNTone.Cyan, label = "Export private key",
                    sub = "Back up or move this account",
                ) { exportKey = true }
                SNSettingsRow(
                    icon = SNIconName.Check, label = "Read receipts",
                    toggle = state.prefBool("readReceipts"),
                ) { state.togglePref("readReceipts") }
                SNSettingsRow(
                    icon = SNIconName.Pin, label = "Message requests",
                ) { requests = true }
                SNSettingsRow(
                    icon = SNIconName.ShieldCheck, tone = SNTone.Cyan, label = "Verified people",
                    value = state.verifiedCount().toString(),
                ) { state.push(Screen.Nearby) }
                SNSettingsRow(
                    icon = SNIconName.Trash, tone = SNTone.Cyan, label = "Erase all chats",
                    sub = "Clears conversations — keeps your identity",
                ) { eraseAsk = true }
                SNSettingsRow(
                    icon = SNIconName.Trash, tone = SNTone.Red, label = "Emergency wipe",
                    sub = "Deletes your key, chats and nickname",
                    danger = true, trail = SNTrail.None, divider = false,
                ) { wipeAsk = true }
            }
            Text(
                "Tip: triple-tap the Sonar title on the home screen to wipe instantly.",
                color = s.text3, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 26.dp, vertical = 6.dp)
            )

            SNSectionLabel("Data & storage")
            SNSettingsCard {
                SNSettingsRow(icon = SNIconName.Pin, label = "Storage", value = "Local only", trail = SNTrail.None) {}
                // Desktop-only: no GPS sensor, so offer opt-in IP geolocation to
                // populate the "Around you" geohash channels. Hidden on mobile
                // (configurable() == false there). Off by default — enabling it
                // sends your IP to a location service.
                if (chat.bitchat.sonar.LocationChannels.configurable()) {
                    SNSettingsRow(
                        icon = SNIconName.Globe, tone = SNTone.Cyan, label = "Approximate location",
                        sub = "Find nearby channels via your IP — sends your IP to a location service",
                        toggle = state.prefBool("ipLocation"),
                    ) {
                        state.togglePref("ipLocation")
                        state.refreshLocationChannels()
                    }
                }
                SNSettingsRow(
                    icon = SNIconName.Globe, label = "Data usage",
                    value = if (state.prefBool("wifiOnly")) "Wi-Fi only" else "Always",
                    toggle = state.prefBool("wifiOnly"), trail = SNTrail.None, divider = false,
                ) { state.togglePref("wifiOnly") }
            }

            SNSectionLabel("About")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Info, label = "About Sonar",
                    sub = "Open protocols — Bluetooth mesh + Nostr", trail = SNTrail.None,
                ) {}
                SNSettingsRow(
                    icon = SNIconName.People, label = "Help", trail = SNTrail.None, divider = false,
                ) { state.toast = "Sonar — open protocols over Bluetooth mesh + Nostr" }
            }
            Spacer(Modifier.height(40.dp))
        }
    }

    if (wipeAsk) WipeSheet(onWipe = { wipeAsk = false; state.wipe() }, onClose = { wipeAsk = false })
    if (eraseAsk) EraseChatsSheet(onErase = { eraseAsk = false; state.eraseAllChats() }, onClose = { eraseAsk = false })
    if (exportKey) ExportKeySheet(state, onClose = { exportKey = false })
    if (currencyPick) CurrencySheet(
        selected = state.currency,
        onPick = { state.selectCurrency(it); currencyPick = false },
        onClose = { currencyPick = false },
    )
    if (notif) NotifSheet(state) { notif = false }
    if (appicon) AppIconSheet(state) { appicon = false }
    if (requests) RequestsSheet { requests = false }

    state.toast?.let { ToastBar(it) { state.toast = null } }
}

@Composable
private fun ExportKeySheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val clipboard = LocalClipboardManager.current
    var revealed by remember { mutableStateOf(false) }
    val nsec = state.exportNsec()
    val masked = if (nsec.isBlank()) "No private key loaded" else nsec.take(5) + " " + "*".repeat(28)
    Sheet("Export private key", onClose) {
        Text(
            "This nsec key controls your Sonar account and wallet. Keep it private.",
            color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
        )
        Spacer(Modifier.height(12.dp))
        Box(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(s.surface2)
                .clickable(enabled = nsec.isNotBlank()) { revealed = !revealed }
                .padding(horizontal = 14.dp, vertical = 13.dp)
        ) {
            Text(
                if (revealed) nsec else masked,
                color = if (nsec.isBlank()) s.text3 else s.text,
                style = SonarType.mono(13.5),
                lineHeight = 18.sp,
            )
        }
        Spacer(Modifier.height(12.dp))
        Box(
            Modifier.fillMaxWidth().height(46.dp).clip(RoundedCornerShape(13.dp))
                .background(if (nsec.isBlank()) s.surface2 else s.accentFill)
                .clickable(enabled = nsec.isNotBlank()) {
                    if (revealed) {
                        clipboard.setText(AnnotatedString(nsec))
                        state.toast = "Private key copied"
                    } else {
                        revealed = true
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (revealed) "Copy private key" else "Reveal private key",
                color = if (nsec.isBlank()) s.text3 else s.onAccent,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
private fun NotifSheet(state: SonarAppState, onClose: () -> Unit) {
    state.prefsVersion
    Sheet("Notifications", onClose) {
        SNSettingsRow(
            icon = SNIconName.Info, label = "Allow notifications",
            toggle = state.prefBool("notifs", true), trail = SNTrail.None,
        ) {
            state.togglePref("notifs", true)
            syncPushEnabled(state)
        }
        SNSettingsRow(
            icon = SNIconName.People, label = "Show names",
            sub = "Hide to keep the lock screen private",
            toggle = state.prefBool("notifNames", true) && state.prefBool("notifs", true), trail = SNTrail.None,
        ) { state.togglePref("notifNames", true) }
        SNSettingsRow(
            icon = SNIconName.Pin, label = "Show message preview",
            toggle = state.prefBool("notifPreview", false) && state.prefBool("notifs", true),
            trail = SNTrail.None,
        ) { state.togglePref("notifPreview", false) }
        SNSettingsRow(
            icon = SNIconName.Bolt, label = "Background push",
            sub = "Receive messages when Sonar is closed",
            toggle = state.prefBool("pushEnabled", true) && state.prefBool("notifs", true),
            trail = SNTrail.None, divider = false,
        ) {
            val newValue = !state.prefBool("pushEnabled", true)
            state.setPref("pushEnabled", newValue)
            syncPushEnabled(state)
        }
    }
}

private fun syncPushEnabled(state: SonarAppState) {
    Notifier.setPushEnabled(
        state.prefBool("notifs", true) && state.prefBool("pushEnabled", true)
    )
}

@Composable
private fun AppIconSheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val icons = listOf(
        Triple("cyan", s.accentFill, s.onAccent),
        Triple("midnight", Color(0xFF0B0E10), Color(0xFF22D3EE)),
        Triple("paper", Color(0xFFF2F6F7), Color(0xFF0891B2)),
    )
    val current = state.prefStr("icon", "cyan")
    Sheet("App icon", onClose) {
        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally)) {
            icons.forEach { (id, bg, fg) ->
                Box(
                    Modifier.size(64.dp).clip(RoundedCornerShape(16.dp)).background(bg)
                        .clickable { state.setPrefStr("icon", id); onClose() },
                    contentAlignment = Alignment.Center
                ) {
                    SNIcon(SNIconName.Rings, 30.dp, fg)
                    if (id == current) Box(Modifier.fillMaxWidth().height(64.dp))
                }
            }
        }
        Text("Quiet options only — no badges, no noise.", color = s.text3, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun RequestsSheet(onClose: () -> Unit) {
    val s = sonar
    Sheet("Message requests", onClose) {
        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            SonarAvatar("driftwood", 46.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("driftwood", color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text("Met on mesh · wants to message you", color = s.text3, fontSize = 12.5.sp)
            }
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).background(s.accentFill).clickable(onClick = onClose).padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
                Text("Accept", color = s.onAccent, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            }
            Box(Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).background(s.surface2).clickable(onClick = onClose).padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
                Text("Decline", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/** Generic bottom sheet shell. */
@Composable
private fun Sheet(title: String, onClose: () -> Unit, content: @Composable () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        androidx.compose.material3.Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text(title, color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(10.dp))
                content()
                Spacer(Modifier.height(10.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Done", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun EraseChatsSheet(onErase: () -> Unit, onClose: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        androidx.compose.material3.Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text("Erase all chats", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(
                    "This deletes every conversation from this phone — Bluetooth chats and White Noise secure chats. Your identity, nickname and wallet stay, so you can start fresh without setting up again.",
                    color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                )
                Spacer(Modifier.height(16.dp))
                SNPrimaryButton("Erase all chats", net = false) { onErase() }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Cancel", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun WipeSheet(onWipe: () -> Unit, onClose: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        androidx.compose.material3.Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text("Emergency wipe", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(
                    "This deletes your identity, wallet, all chats and your nickname from this phone. It can’t be undone.",
                    color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                )
                Spacer(Modifier.height(16.dp))
                SNPrimaryButton("Wipe everything", net = false) { onWipe() }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Cancel", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun CurrencySheet(selected: FiatCurrency, onPick: (FiatCurrency) -> Unit, onClose: () -> Unit) {
    val s = sonar
    Sheet("Display currency", onClose) {
        FiatCurrency.entries.forEach { c ->
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                    .clickable { onPick(c) }.padding(vertical = 12.dp, horizontal = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("${c.code} · ${c.symbol.trim()}", color = s.text, fontSize = 16.sp, modifier = Modifier.weight(1f))
                if (c == selected) SNIcon(SNIconName.ShieldCheck, 18.dp, s.accent)
            }
        }
    }
}

internal fun formatThousands(n: Long): String =
    n.toString().reversed().chunked(3).joinToString(",").reversed()

internal fun shortKey(npub: String?): String {
    val k = npub ?: return "connecting…"
    return if (k.length > 18) k.take(12) + "…" + k.takeLast(4) else k
}
