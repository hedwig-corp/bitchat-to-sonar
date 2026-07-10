package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAccountRestoreException
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarClock
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.ToastBar
import chat.bitchat.sonar.TranscriptPolicyHostDemo
import chat.bitchat.sonar.TranscriptSpikeBDemo
import chat.bitchat.sonar.sonarTranscriptPolicyHostEntryVisible
import chat.bitchat.sonar.sonarTranscriptSpikeBEntryVisible
import kotlinx.coroutines.launch
import chat.bitchat.sonar.wallet.FiatCurrency
import chat.bitchat.sonar.wallet.WalletState
import chat.bitchat.sonar.ui.SNGhostButton
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
import kotlinx.coroutines.delay

/**
 * Full Settings screen — 1:1 reproduction of design/handoff/project/sonar/
 * settings.jsx (Signal/XChat-inspired): profile card, App / Network / Wallet /
 * Privacy & safety / Data & storage / About sections, with the Notifications,
 * App icon, Message-requests, Currency, Export-key and Wipe sheets. Real
 * backends are bound where they exist; demo-only rows persist their toggle
 * locally.
 */
@Composable
fun SonarSettingsScreen(state: SonarAppState) {
    val s = sonar
    var wipeAsk by remember { mutableStateOf(false) }
    var eraseAsk by remember { mutableStateOf(false) }
    var exportKey by remember { mutableStateOf(false) }
    var restoreKey by remember { mutableStateOf(false) }
    var currencyPick by remember { mutableStateOf(false) }
    var notif by remember { mutableStateOf(false) }
    var appicon by remember { mutableStateOf(false) }
    var requests by remember { mutableStateOf(false) }
    var diagnostics by remember { mutableStateOf(false) }
    var transcriptSpikeB by remember { mutableStateOf(false) }
    var transcriptPolicyHost by remember { mutableStateOf(false) }
    var linkedDevices by remember { mutableStateOf(false) }
    state.prefsVersion // subscribe so toggles recompose

    val balance = (state.walletState as? WalletState.Ready)?.balanceSats ?: 0L
    val iconLabel = when (state.prefStr("icon", "cyan")) {
        "midnight" -> "Midnight"; "paper" -> "Paper"; else -> "Cyan"
    }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Settings", hairline = false, onBack = { state.back() })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // st-prof: profile card → Profile
            Row(
                Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = 4.dp)
                    .clip(RoundedCornerShape(20.dp)).background(s.surface)
                    .clickable { state.push(Screen.Profile) }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SonarAvatar(state.nick.ifBlank { "you" }, 56.dp)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(state.nick.ifBlank { "you" }, color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Text(shortKey(state.npub), color = s.text3, style = SonarType.mono(12.0), modifier = Modifier.padding(top = 2.dp))
                }
                SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
            }

            SNSectionLabel("App")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Moon, label = "Appearance",
                    value = if (state.dark) "Dark" else "Light",
                ) { state.toggleDark() }
                SNSettingsRow(
                    icon = SNIconName.Rings, label = "App icon", value = iconLabel,
                ) { appicon = true }
                SNXSettingsRow(
                    label = "Notifications",
                    value = if (state.prefBool("notifs", true)) "On" else "Off",
                    chevron = true, divider = false,
                    icon = { SNXIcon(SNXIconName.Bell, 18.dp, it) },
                ) { notif = true }
            }

            SNSectionLabel("Network")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Mesh, tone = SNTone.Cyan, label = "Connection",
                    sub = if (state.started) "Bluetooth + internet" else "Nearby only, no internet",
                    value = if (state.started) "Online" else "Bluetooth only",
                ) {}
                SNSettingsRow(
                    icon = SNIconName.Mesh, tone = SNTone.Cyan, label = "Discover new people",
                    sub = state.bleDiscoverySettingsDescription,
                    toggle = state.discoverNewPeople,
                    trail = SNTrail.None, divider = false,
                ) {
                    state.setBleDiscoverNewPeople(!state.discoverNewPeople)
                }
            }

            SNSectionLabel("Wallet")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Coin, tone = SNTone.Gold, label = "Balance",
                    value = if (state.walletAvailable) state.money(balance) else "Unavailable",
                    divider = state.walletAvailable,
                ) { if (state.walletAvailable) state.push(Screen.WalletActivity) }
                if (state.walletAvailable) {
                    SNSettingsRow(
                        icon = SNIconName.Globe, label = "Currency", value = state.currency.code,
                    ) { currencyPick = true }
                    SNSettingsRow(
                        icon = SNIconName.Bolt, label = "Bitcoin mode",
                        sub = "Show sats and bitcoin networks",
                        toggle = !state.showFiat, trail = SNTrail.None, divider = false,
                    ) { state.toggleShowFiat() }
                }
            }
            if (state.walletAvailable) {
                StNote("Off by default — amounts show in your currency. Turn on to see sats, Lightning and ecash.")
            } else {
                StNote("This build has no Breez API key, so Lightning stays off. Chat and restore still work.")
            }

            SNSectionLabel("Privacy & safety")
            SNSettingsCard {
                SNXSettingsRow(
                    label = "App lock",
                    sub = "Require your device unlock to open Sonar",
                    toggle = state.appLockOn,
                    icon = { SNXIcon(SNXIconName.FaceId, 18.dp, it) },
                ) {
                    if (state.appLockAvailable) state.setAppLock(!state.appLockOn)
                    else state.toast = "Set a screen lock on your device first"
                }
                SNSettingsRow(
                    icon = SNIconName.Check, label = "Read receipts",
                    toggle = state.prefBool("readReceipts"),
                ) { state.togglePref("readReceipts") }
                SNXSettingsRow(
                    label = "Message requests",
                    chevron = true,
                    icon = { SNXIcon(SNXIconName.Inbox, 18.dp, it) },
                ) { requests = true }
                SNSettingsRow(
                    icon = SNIconName.ShieldCheck, tone = SNTone.Cyan, label = "Verified people",
                    value = state.verifiedCount().toString(),
                ) { state.push(Screen.Nearby) }
                SNSettingsRow(
                    icon = SNIconName.Link, tone = SNTone.Cyan, label = "Linked devices",
                    sub = "Use this account on another phone or computer",
                ) { linkedDevices = true }
                SNXSettingsRow(
                    label = "Export private key",
                    sub = "Back up your nsec — needed to restore on another phone",
                    chevron = true,
                    icon = { SNXIcon(SNXIconName.ImportKey, 18.dp, it) },
                ) { exportKey = true }
                SNXSettingsRow(
                    label = "Restore account",
                    sub = "Replace this account with an nsec from a backup",
                    chevron = true,
                    icon = { SNXIcon(SNXIconName.ImportKey, 18.dp, it) },
                ) { restoreKey = true }
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
            StNote("Tip: triple-tap the sonar title on the home screen to wipe instantly.")

            SNSectionLabel("Data & storage")
            SNSettingsCard {
                SNXSettingsRow(
                    label = "Storage", value = "Local only",
                    icon = { SNXIcon(SNXIconName.Drive, 18.dp, it) },
                ) {}
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
                SNXSettingsRow(
                    label = "Data usage",
                    value = if (state.prefBool("wifiOnly")) "Wi-Fi only" else "Always",
                    toggle = state.prefBool("wifiOnly"), divider = false,
                    icon = { SNXIcon(SNXIconName.Data, 18.dp, it) },
                ) { state.togglePref("wifiOnly") }
            }

            if (sonarTranscriptSpikeBEntryVisible || sonarTranscriptPolicyHostEntryVisible) {
                SNSectionLabel("Developer")
                SNSettingsCard {
                    if (sonarTranscriptSpikeBEntryVisible) {
                        SNSettingsRow(
                            icon = SNIconName.Info,
                            label = "Transcript Spike B",
                            sub = "Signal-Android reverseLayout / stack-from-end host",
                            divider = sonarTranscriptPolicyHostEntryVisible,
                        ) { transcriptSpikeB = true }
                    }
                    if (sonarTranscriptPolicyHostEntryVisible) {
                        SNSettingsRow(
                            icon = SNIconName.Info,
                            label = "Transcript Phase 2 host",
                            sub = "Signal engine demo — production default ON (kill switch: =0)",
                            divider = false,
                        ) { transcriptPolicyHost = true }
                    }
                }
            }

            SNSectionLabel("About")
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.Info, label = "Diagnostics",
                    sub = "Relay sync status and shareable debug logs",
                ) { diagnostics = true }
                SNSettingsRow(
                    icon = SNIconName.Info, label = "About Sonar",
                    sub = "Open protocols — Bluetooth mesh + Nostr",
                ) {}
                SNXSettingsRow(
                    label = "Help", divider = false,
                    trailing = { SNXIcon(SNXIconName.ArrowOut, 14.dp, s.text3, weight = 2.2f) },
                    icon = { SNIcon(SNIconName.Smile, 18.dp, it) },
                ) { state.toast = "Sonar — open protocols over Bluetooth mesh + Nostr" }
            }
            Spacer(Modifier.height(56.dp))
        }
    }

    if (wipeAsk) WipeSheet(onWipe = { wipeAsk = false; state.wipe() }, onClose = { wipeAsk = false })
    if (eraseAsk) EraseChatsSheet(onErase = { eraseAsk = false; state.eraseAllChats() }, onClose = { eraseAsk = false })
    if (exportKey) ExportKeySheet(state, onClose = { exportKey = false })
    if (restoreKey) RestoreAccountSheet(state, onClose = { restoreKey = false })
    if (currencyPick) CurrencySheet(
        selected = state.currency,
        onPick = { state.selectCurrency(it); currencyPick = false },
        onClose = { currencyPick = false },
    )
    if (notif) NotifSheet(state) { notif = false }
    if (appicon) AppIconSheet(state) { appicon = false }
    if (requests) RequestsSheet { requests = false }
    if (diagnostics) DiagnosticsSheet(state) { diagnostics = false }
    if (transcriptSpikeB) {
        Box(Modifier.fillMaxSize()) {
            TranscriptSpikeBDemo(onClose = { transcriptSpikeB = false })
        }
    }
    if (transcriptPolicyHost) {
        Box(Modifier.fillMaxSize()) {
            TranscriptPolicyHostDemo(onClose = { transcriptPolicyHost = false })
        }
    }
    if (linkedDevices) LinkedDevicesSheet(state) { linkedDevices = false }

    state.toast?.let { ToastBar(it) { state.toast = null } }
}

/** st-note: 12px text3 hanging under a card (padding 0 24px 4px). */
@Composable
private fun StNote(text: String) {
    Text(
        text, color = sonar.text3, fontSize = 12.sp, lineHeight = 18.sp,
        modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 4.dp)
    )
}

/**
 * Design bottom sheet (bc-scrim + bc-sheet): floating card with 10dp side /
 * 12dp bottom margins, 24dp radius, a grabber, and an uppercase title.
 */
@Composable
internal fun Sheet(title: String?, onClose: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
            onClick = onClose,
        ),
        contentAlignment = Alignment.BottomCenter
    ) {
        Column(
            Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, bottom = 12.dp)
                .clip(RoundedCornerShape(24.dp)).background(s.surface)
                .clickable(  // swallow taps on the sheet itself
                    interactionSource = remember { MutableInteractionSource() }, indication = null,
                    onClick = {},
                )
                .padding(start = 10.dp, end = 10.dp, top = 4.dp, bottom = 14.dp)
        ) {
            // bc-grabber
            Box(
                Modifier.align(Alignment.CenterHorizontally).padding(top = 8.dp, bottom = 8.dp)
                    .size(width = 38.dp, height = 4.5.dp).clip(RoundedCornerShape(3.dp)).background(s.hairline)
            )
            if (title != null) {
                Text(
                    title.uppercase(), color = s.text3, fontSize = 12.5.sp,
                    fontWeight = FontWeight.Bold, letterSpacing = 0.6.sp,
                    modifier = Modifier.padding(start = 10.dp, end = 10.dp, top = 2.dp, bottom = 8.dp)
                )
            }
            content()
        }
    }
}

/** bc-verifycopy: centered explainer copy inside a sheet. */
@Composable
private fun SheetCopy(text: String) {
    Text(
        text, color = sonar.text2, fontSize = 13.5.sp, lineHeight = 20.sp,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = 2.dp)
    )
}

/** bc-primary.danger */
@Composable
private fun DangerPrimaryButton(label: String, onClick: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxWidth().height(52.dp).clip(RoundedCornerShape(15.dp))
            .background(s.danger).clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(label, color = Color(0xFFFFF6F6), fontSize = 16.5.sp, fontWeight = FontWeight.Bold)
    }
}

/** Emergency wipe confirmation — copy verbatim from screens.jsx WipeSheet. */
@Composable
private fun WipeSheet(onWipe: () -> Unit, onClose: () -> Unit) {
    Sheet("Emergency wipe", onClose) {
        SheetCopy(
            "This deletes your key, your nickname and every conversation from this phone. " +
                "There is no account to recover — gone is gone."
        )
        Column(Modifier.padding(start = 8.dp, end = 8.dp, top = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            DangerPrimaryButton("Wipe everything") { onWipe() }
            SNGhostButton("Cancel") { onClose() }
        }
    }
}

@Composable
private fun EraseChatsSheet(onErase: () -> Unit, onClose: () -> Unit) {
    Sheet("Erase all chats", onClose) {
        SheetCopy(
            "This deletes every conversation from this phone — Bluetooth chats and White Noise " +
                "secure chats. Your identity, nickname and wallet stay, so you can start fresh " +
                "without setting up again."
        )
        Column(Modifier.padding(start = 8.dp, end = 8.dp, top = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            SNPrimaryButton("Erase all chats", net = false) { onErase() }
            SNGhostButton("Cancel") { onClose() }
        }
    }
}

/** Export private key (nsec) — settings.jsx ExportKeySheet: warning card,
 *  masked reveal field with an eye, copy button, password-manager tip. */
@Composable
private fun ExportKeySheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val clipboard = LocalClipboardManager.current
    var revealed by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1700); copied = false } }
    val nsec = state.exportNsec()
    val masked = if (nsec.isBlank()) "No private key loaded" else nsec.take(5) + " " + "•".repeat(28)
    Sheet("Export private key", onClose) {
        // nsec-warn
        Row(
            Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 2.dp, bottom = 12.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color(s.danger.value).copy(alpha = 0.10f))
                .padding(horizontal = 15.dp, vertical = 13.dp),
        ) {
            SNIcon(SNIconName.Shield, 18.dp, s.danger, weight = 2f)
            Spacer(Modifier.width(11.dp))
            Text(
                buildAnnotatedString {
                    append("This ")
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("nsec") }
                    append(" key ")
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("is") }
                    append(
                        " your account. Anyone who has it can read your messages and spend your " +
                            "balance. Paste it into another Nostr app to move in — never share it with a person."
                    )
                },
                color = s.text, fontSize = 13.sp, lineHeight = 19.5.sp,
            )
        }
        // nsec-field: tap to reveal/hide, eye glyph trailing
        Row(
            Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, bottom = 12.dp)
                .clip(RoundedCornerShape(14.dp)).background(s.surface2)
                .clickable(enabled = nsec.isNotBlank()) { revealed = !revealed }
                .padding(horizontal = 15.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (revealed) nsec else masked,
                color = if (revealed) s.text else s.text2,
                style = SonarType.mono(13.0),
                lineHeight = 19.5.sp,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(10.dp))
            SNXIcon(if (revealed) SNXIconName.EyeOff else SNXIconName.Eye, 17.dp, s.text3, weight = 2f)
        }
        // keyshare-btn primary — Copy private key / Copied
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
            Row(
                Modifier.weight(1f).clip(RoundedCornerShape(13.dp))
                    .background(if (nsec.isBlank()) s.surface2 else if (copied) s.green else s.accentFill)
                    .clickable(enabled = nsec.isNotBlank()) {
                        clipboard.setText(AnnotatedString(nsec))
                        copied = true
                    }
                    .padding(vertical = 12.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val fg = if (nsec.isBlank()) s.text3 else if (copied) Color.White else s.onAccent
                if (copied) SNIcon(SNIconName.Check, 17.dp, fg, weight = 2.2f)
                else SNXIcon(SNXIconName.Copy, 17.dp, fg, weight = 2.2f)
                Spacer(Modifier.width(7.dp))
                Text(
                    if (copied) "Copied" else "Copy private key",
                    color = fg, fontSize = 14.5.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
        Text(
            "Tip: store it in a password manager. Sonar can’t recover it for you.",
            color = s.text3, fontSize = 13.sp, lineHeight = 19.5.sp, textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 12.dp, bottom = 4.dp),
        )
    }
}

@Composable
private fun RestoreAccountSheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val clipboard = LocalClipboardManager.current
    var nsec by remember { mutableStateOf("") }
    var confirmed by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var inFlight by remember { mutableStateOf(false) }
    val nsecOk = nsec.trim().matches(Regex("^nsec1[0-9a-z]{20,}$"))
    Sheet("Restore account", onClose) {
        Row(
            Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 2.dp, bottom = 12.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color(s.danger.value).copy(alpha = 0.10f))
                .padding(horizontal = 15.dp, vertical = 13.dp),
        ) {
            SNIcon(SNIconName.Shield, 18.dp, s.danger, weight = 2f)
            Spacer(Modifier.width(11.dp))
            Text(
                "This replaces the account on this phone. Chats stored here are erased. Your Lightning wallet is rebuilt from the nsec you paste.",
                color = s.text, fontSize = 13.sp, lineHeight = 19.5.sp,
            )
        }
        Box(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp).heightIn(min = 84.dp)
                .clip(RoundedCornerShape(14.dp)).background(s.surface2)
                .padding(horizontal = 15.dp, vertical = 14.dp),
        ) {
            if (nsec.isEmpty()) {
                Text("nsec1...", color = s.text3, fontSize = 15.sp)
            }
            BasicTextField(
                value = nsec,
                onValueChange = { nsec = it },
                textStyle = TextStyle(color = s.text, fontSize = 15.sp, lineHeight = 20.sp),
                cursorBrush = SolidColor(s.accent),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(
            Modifier.padding(horizontal = 8.dp).clip(CircleShape).background(s.accentSoft)
                .clickable { clipboard.getText()?.text?.let { nsec = it.trim() } }
                .padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SNXIcon(SNXIconName.Copy, 16.dp, s.accentDeep, weight = 2f)
            Spacer(Modifier.width(7.dp))
            Text("Paste from clipboard", color = s.accentDeep, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(8.dp))
        SNSettingsRow(
            icon = SNIconName.ShieldCheck,
            label = "I understand chats on this phone will be erased",
            toggle = confirmed,
            divider = false,
        ) { confirmed = !confirmed }
        if (error != null) {
            Text(
                error!!,
                color = s.danger,
                fontSize = 13.sp,
                lineHeight = 17.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
        Column(
            Modifier.padding(start = 8.dp, end = 8.dp, top = 6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            SNPrimaryButton(
                if (inFlight) "Restoring..." else "Restore account",
                disabled = !nsecOk || !confirmed || inFlight,
            ) {
                inFlight = true
                error = null
                state.restoreAccount(nsec.trim()) { result ->
                    inFlight = false
                    result.exceptionOrNull()?.let { failure ->
                        error = (failure as? SonarAccountRestoreException)?.message
                            ?: "Account restore failed. Restart Sonar and try again."
                    } ?: onClose()
                }
            }
            SNGhostButton("Cancel") { onClose() }
        }
    }
}

@Composable
private fun NotifSheet(state: SonarAppState, onClose: () -> Unit) {
    state.prefsVersion
    Sheet("Notifications", onClose) {
        SNXSettingsRow(
            label = "Allow notifications",
            toggle = state.prefBool("notifs", true),
            icon = { SNXIcon(SNXIconName.Bell, 18.dp, it) },
        ) {
            state.togglePref("notifs", true)
            syncPushEnabled(state)
        }
        SNSettingsRow(
            icon = SNIconName.People, label = "Show names",
            sub = "Hide to keep the lock screen private",
            toggle = state.prefBool("notifNames", true) && state.prefBool("notifs", true), trail = SNTrail.None,
        ) { state.togglePref("notifNames", true) }
        SNXSettingsRow(
            label = "Show message preview",
            toggle = state.prefBool("notifPreview", false) && state.prefBool("notifs", true),
            icon = { SNXIcon(SNXIconName.ListGlyph, 18.dp, it) },
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
        Column(Modifier.padding(start = 8.dp, end = 8.dp, top = 6.dp)) {
            SNGhostButton("Done") { onClose() }
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
        // ai-row: 62dp tiles, 15dp radius, accent ring on the selected one
        Row(
            Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterHorizontally)
        ) {
            icons.forEach { (id, bg, fg) ->
                Box(
                    Modifier.size(62.dp).clip(RoundedCornerShape(15.dp))
                        .background(bg)
                        .then(
                            if (id == current) Modifier.border(2.5.dp, s.accent, RoundedCornerShape(15.dp))
                            else Modifier
                        )
                        .clickable { state.setPrefStr("icon", id); onClose() },
                    contentAlignment = Alignment.Center
                ) {
                    SNIcon(SNIconName.Rings, 30.dp, fg)
                }
            }
        }
        SheetCopy("The Sonar mark — quiet, no badges.")
        Column(Modifier.padding(start = 8.dp, end = 8.dp, top = 6.dp)) {
            SNGhostButton("Done") { onClose() }
        }
    }
}

@Composable
private fun RequestsSheet(onClose: () -> Unit) {
    val s = sonar
    Sheet("Message requests", onClose) {
        // pf-request
        Row(
            Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SonarAvatar("driftwood", 46.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("driftwood", color = s.text, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                Text("Met on mesh · wants to message you", color = s.text2, fontSize = 12.5.sp)
            }
        }
        // pf-reqbtns
        Row(
            Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(999.dp)).background(s.accentFill)
                    .clickable(onClick = onClose).padding(vertical = 11.dp),
                contentAlignment = Alignment.Center
            ) { Text("Accept", color = s.onAccent, fontSize = 14.sp, fontWeight = FontWeight.Bold) }
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(999.dp)).background(s.surface2)
                    .clickable(onClick = onClose).padding(vertical = 11.dp),
                contentAlignment = Alignment.Center
            ) { Text("Decline", color = s.text, fontSize = 14.sp, fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun DiagnosticsSheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val scope = rememberCoroutineScope()
    state.prefsVersion
    var snapshot by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        snapshot = SonarCore.syncStateSnapshotJson()
        loaded = true
    }
    Sheet("Diagnostics", onClose) {
        // Relay/sync summary parsed from the snapshot JSON (format owned by
        // the Rust core's SyncStateSnapshot; extraction kept intentionally
        // tolerant — a missing field just hides that line).
        val summary = snapshot?.let { json ->
            val connected = Regex("\"status\": \"Connected\"").findAll(json).count()
            val total = Regex("\"url\":").findAll(json).count()
            val watermark = Regex("\"watermark_secs\": (\\d+)").find(json)
                ?.groupValues?.get(1)?.toLongOrNull() ?: 0L
            val ago = SonarClock.nowSecs() - watermark
            val sync = when {
                watermark == 0L -> "never"
                ago < 60 -> "just now"
                ago < 3600 -> "${ago / 60} min ago"
                ago < 86400 -> "${ago / 3600} h ago"
                else -> "${ago / 86400} d ago"
            }
            "$connected/$total relays connected · Last sync: $sync"
        } ?: if (loaded) "Relay not connected yet" else "Loading…"
        Text(summary, color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp)
        Spacer(Modifier.height(12.dp))
        SNSettingsRow(
            icon = SNIconName.Search, label = "Verbose logs",
            sub = "Adds debug detail to captured logs. Never includes your private key.",
            toggle = state.prefBool("diagVerbose"), trail = SNTrail.None, divider = false,
        ) {
            state.togglePref("diagVerbose")
            SonarCore.setDiagnosticsVerbose(state.prefBool("diagVerbose"))
        }
        Spacer(Modifier.height(12.dp))
        Box(
            Modifier.fillMaxWidth().height(46.dp).clip(RoundedCornerShape(13.dp))
                .background(if (exporting) s.surface2 else s.accentFill)
                .clickable(enabled = !exporting) {
                    exporting = true
                    scope.launch {
                        val shared = SonarCore.exportDiagnostics()
                        exporting = false
                        if (!shared) state.toast = "Nothing to share yet — no logs captured"
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (exporting) "Preparing…" else "Share debug bundle",
                color = if (exporting) s.text3 else s.onAccent,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(
            "Logs stay on this device until you share them. They contain relay and sync events — no message text and no keys.",
            color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
        )
    }
}

/** Settings → Linked devices: add another device of THIS account as a second
 *  MLS leaf in every admin chat. The NEW device shows a link code (a fresh
 *  KeyPackage `d`-tag prefix); the OLD device enters it and runs the link
 *  pass. History does not move — the new device sees messages from the moment
 *  it is linked (tracked gap). */
@Composable
private fun LinkedDevicesSheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val scope = rememberCoroutineScope()
    var linkCode by remember { mutableStateOf<String?>(null) }
    var generating by remember { mutableStateOf(false) }
    var entered by remember { mutableStateOf("") }
    var linking by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<chat.bitchat.sonar.SonarDeviceLinkResult?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    Sheet("Linked devices", onClose) {
        // This device: show a link code (use on the NEW device).
        Text("THIS DEVICE", color = s.text3, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        val code = linkCode
        if (code != null) {
            Text(
                code.chunked(4).joinToString(" "),
                color = s.text, style = SonarType.mono(20.0),
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                "On your other device: Settings → Linked devices → enter this code, then keep this device online.",
                color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
            )
        } else {
            Box(
                Modifier.fillMaxWidth().height(46.dp).clip(RoundedCornerShape(13.dp))
                    .background(if (generating) s.surface2 else s.accentFill)
                    .clickable(enabled = !generating) {
                        generating = true
                        scope.launch {
                            try {
                                linkCode = SonarCore.createDeviceLinkCode()
                            } catch (_: Exception) {
                                state.toast = "Could not publish a link code — check your connection"
                            } finally {
                                generating = false
                            }
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (generating) "Publishing…" else "Show link code",
                    color = if (generating) s.text3 else s.onAccent,
                    fontSize = 15.sp, fontWeight = FontWeight.Bold,
                )
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "Use this on the device you are ADDING (your new phone). It publishes a fresh key so your other device can link it.",
                color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
            )
        }

        Spacer(Modifier.height(16.dp))

        // Old device: enter the code shown on the new device.
        Text("LINK A NEW DEVICE", color = s.text3, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Box(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(13.dp)).background(s.surface2)
                .padding(horizontal = 14.dp, vertical = 12.dp)
        ) {
            if (entered.isEmpty()) Text("Link code from the new device", color = s.text3, fontSize = 14.sp)
            BasicTextField(
                value = entered, onValueChange = { entered = it.trim() },
                textStyle = SonarType.mono(14.0).copy(color = s.text),
                cursorBrush = SolidColor(s.accent),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(Modifier.height(8.dp))
        val plausible = entered.length >= 8 && entered.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }
        Box(
            Modifier.fillMaxWidth().height(46.dp).clip(RoundedCornerShape(13.dp))
                .background(if (linking || !plausible) s.surface2 else s.accentFill)
                .clickable(enabled = !linking && plausible) {
                    linking = true
                    error = null
                    result = null
                    scope.launch {
                        try {
                            result = SonarCore.linkDevice(entered)
                        } catch (e: Exception) {
                            error = e.message ?: "Linking failed — try again"
                        } finally {
                            linking = false
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (linking) "Linking…" else "Link device",
                color = if (linking || !plausible) s.text3 else s.onAccent,
                fontSize = 15.sp, fontWeight = FontWeight.Bold,
            )
        }
        error?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, color = s.danger, fontSize = 12.5.sp, lineHeight = 17.sp)
        }
        result?.let { r ->
            val linked = r.outcomes.count { it.status == "linked" }
            val already = r.outcomes.count { it.status == "already_linked" }
            val skipped = r.outcomes.filter { it.status == "skipped_not_admin" }
            val failed = r.outcomes.filter { it.status == "failed" }
            Spacer(Modifier.height(10.dp))
            Text(
                "$linked chat${if (linked == 1) "" else "s"} linked" +
                    if (already > 0) " · $already already linked" else "",
                color = s.text, fontSize = 13.5.sp,
            )
            skipped.forEach {
                Text(
                    "Skipped ${it.name.ifBlank { "unnamed chat" }} — you are not an admin there",
                    color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
                )
            }
            failed.forEach {
                Text(
                    "Failed ${it.name.ifBlank { "unnamed chat" }}: ${it.error ?: "unknown error"}",
                    color = s.danger, fontSize = 12.5.sp, lineHeight = 17.sp,
                )
            }
            if (failed.isNotEmpty()) {
                Text(
                    "You can safely run the link again with the same code.",
                    color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
                )
            }
        }

        Spacer(Modifier.height(10.dp))
        Text(
            "Linking adds your other device to every chat where you are an admin. New messages appear on both devices; older history stays on this one.",
            color = s.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
        )
    }
}

private val CURRENCY_NAMES = mapOf(
    "EUR" to "Euro", "USD" to "US Dollar", "GBP" to "British Pound", "CHF" to "Swiss Franc",
)

@Composable
private fun CurrencySheet(selected: FiatCurrency, onPick: (FiatCurrency) -> Unit, onClose: () -> Unit) {
    val s = sonar
    Sheet("Currency", onClose) {
        FiatCurrency.entries.forEach { c ->
            SNXSettingsRow(
                label = c.code,
                sub = CURRENCY_NAMES[c.code] ?: c.code,
                value = c.symbol.trim(),
                divider = false,
                trailing = if (c == selected) {
                    { SNIcon(SNIconName.Check, 16.dp, s.accent, weight = 2.2f) }
                } else null,
                icon = { SNIcon(SNIconName.Globe, 18.dp, it) },
            ) { onPick(c) }
        }
        Column(Modifier.padding(start = 8.dp, end = 8.dp, top = 6.dp)) {
            SNGhostButton("Done") { onClose() }
        }
    }
}

internal fun formatThousands(n: Long): String =
    n.toString().reversed().chunked(3).joinToString(",").reversed()

/** Design short key: `pubkey.slice(0, 14) + '…' + pubkey.slice(-6)`. */
internal fun shortKey(npub: String?): String {
    val k = npub ?: return "connecting…"
    return if (k.length > 20) k.take(14) + "…" + k.takeLast(6) else k
}
