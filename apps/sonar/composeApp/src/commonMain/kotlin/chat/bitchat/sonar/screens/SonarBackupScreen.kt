package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.AccountBackupPreview
import chat.bitchat.sonar.BackupFormat
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarClock
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.ToastBar
import chat.bitchat.sonar.ui.SNGhostButton
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SNSettingsCard
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.sonar

/**
 * Chat backup — 1:1 with design/handoff/project/sonar/settings.jsx `BackupScreen`.
 *
 * Two layouts behind one hero: on, where the card carries the toggle, cadence
 * and last-backup rows above a stats strip; off, where three feature rows sit
 * above a bottom call to action. Every figure is real — the design's 128 MB and
 * 1,204 messages are prototype fiction, so an unmeasured value renders as a dash
 * rather than a confident zero.
 */
@Composable
fun SonarBackupScreen(state: SonarAppState) {
    val s = sonar
    var freqSheet by remember { mutableStateOf(false) }
    var setupSheet by remember { mutableStateOf(false) }
    var dryRun by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        state.discloseAutoBackup()
        state.refreshBackupPolicy()
    }
    state.backupInProgress // subscribe so the row reflects an in-flight upload

    val policy = state.backupPolicy
    val on = state.autoBackupEnabled
    val lastBackup = BackupFormat.lastBackup(policy?.lastSuccessAt, SonarClock.nowSecs())

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader("Chat backup", hairline = false, onBack = { state.back() })
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            BackupHero(on)

            if (on) {
                SNSettingsCard {
                    SNSettingsRow(
                        icon = SNIconName.ShieldCheck, tone = SNTone.Cyan,
                        label = "Backup", value = "On", toggle = true,
                    ) { state.updateAutoBackupEnabled(false) }
                    SNSettingsRow(
                        icon = SNIconName.Data, label = "Frequency",
                        value = BackupFormat.frequencyLabel(policy?.frequency ?: "daily"),
                    ) { freqSheet = true }
                    SNSettingsRow(
                        icon = SNIconName.Drive, label = "Last backup",
                        sub = "Restores automatically · tap for a dry run",
                        value = lastBackup ?: "Never", divider = false,
                    ) { dryRun = true }
                }
                BackupStats(
                    size = BackupFormat.bytes(policy?.lastSizeBytes),
                    messages = BackupFormat.count(policy?.lastMessageCount),
                )
                BackupNote(
                    "Backups are encrypted on this device before upload. " +
                        "Sonar's servers only ever see ciphertext.",
                )
                Spacer(Modifier.height(8.dp))
                SNSettingsCard {
                    SNSettingsRow(
                        icon = SNIconName.ImportKey, label = "Dry run a restore",
                        sub = "Preview what would come back — changes nothing",
                        divider = false,
                    ) { dryRun = true }
                }
            } else {
                SNSettingsCard {
                    BackupFeature(
                        SNIconName.Lock, "Encrypted by default",
                        "Sealed with the key already on this phone.",
                    )
                    BackupFeature(
                        SNIconName.Data, "Automatic",
                        "Runs quietly in the background, on your schedule.",
                    )
                    BackupFeature(
                        SNIconName.ImportKey, "Restores automatically",
                        "Sign in on a new phone and your history comes back on its own.",
                        divider = false,
                    )
                }
                Spacer(Modifier.height(8.dp))
                SNSettingsCard {
                    SNSettingsRow(
                        icon = SNIconName.ImportKey, label = "Dry run a restore",
                        sub = "Preview what would come back — changes nothing",
                        divider = false,
                    ) { dryRun = true }
                }
            }
            Spacer(Modifier.height(16.dp))
        }

        if (!on) {
            Column(
                Modifier.fillMaxWidth()
                    .padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 30.dp),
            ) {
                SNPrimaryButton("Turn on backup", Modifier.fillMaxWidth()) { setupSheet = true }
                Text(
                    "Encrypted with the key already on this phone — nothing to write down.",
                    color = s.text3, fontSize = 12.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            }
        }
    }

    if (setupSheet) {
        BackupSetupSheet(
            onDone = { state.updateAutoBackupEnabled(true) },
            onClose = { setupSheet = false },
        )
    }
    if (freqSheet) {
        BackupFrequencySheet(
            selected = policy?.frequency ?: "daily",
            onPick = { state.updateBackupFrequency(it) },
            onClose = { freqSheet = false },
        )
    }
    if (dryRun) {
        BackupDryRunSheet { dryRun = false }
    }
    state.toast?.let { ToastBar(it) { state.toast = null } }
}

/** bk-hero: icon, title and copy that flip with the on state. */
@Composable
private fun BackupHero(on: Boolean) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(66.dp).clip(RoundedCornerShape(22.dp))
                .background(if (on) s.accentSoft else s.surface2),
            contentAlignment = Alignment.Center,
        ) {
            SNIcon(SNIconName.ShieldCheck, 34.dp, if (on) s.accentDeep else s.text3)
        }
        Text(
            if (on) "Backups are on" else "Back up your chats",
            color = s.text, fontSize = 20.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            if (on) {
                "Your history is encrypted with the key on this phone — " +
                    "nothing extra to remember."
            } else {
                "Keep an encrypted copy of your messages, groups and settings " +
                    "so you can restore on a new phone."
            },
            color = s.text3, fontSize = 13.5.sp, textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

/** bk-stats: three figures side by side; a dash where nothing is measured yet. */
@Composable
private fun BackupStats(size: String?, messages: String?) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        BackupStat(size ?: "—", "backup size", Modifier.weight(1f))
        BackupStat("End-to-end", "encrypted", Modifier.weight(1f))
        BackupStat(messages ?: "—", "messages", Modifier.weight(1f))
    }
}

@Composable
private fun BackupStat(value: String, label: String, modifier: Modifier) {
    val s = sonar
    Column(
        modifier.clip(RoundedCornerShape(16.dp)).background(s.surface).padding(vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(value, color = s.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
        Text(label, color = s.text3, fontSize = 11.5.sp, modifier = Modifier.padding(top = 3.dp))
    }
}

/** bk-feat: an explanatory row used in the off state and the setup sheet. */
@Composable
private fun BackupFeature(
    icon: SNIconName,
    title: String,
    sub: String,
    divider: Boolean = true,
) {
    val s = sonar
    Column {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(34.dp).clip(RoundedCornerShape(11.dp)).background(s.surface2),
                contentAlignment = Alignment.Center,
            ) { SNIcon(icon, 17.dp, s.text2) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, color = s.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    sub, color = s.text3, fontSize = 12.5.sp,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
        if (divider) {
            Box(
                Modifier.fillMaxWidth().padding(start = 60.dp).height(1.dp)
                    .background(s.surface2),
            )
        }
    }
}

@Composable
private fun BackupNote(text: String) {
    val s = sonar
    Text(
        text, color = s.text3, fontSize = 12.sp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
    )
}

/** Turn-on sheet: encrypted automatically, nothing to write down. */
@Composable
private fun BackupSetupSheet(onDone: () -> Unit, onClose: () -> Unit) {
    val s = sonar
    Sheet("Turn on backup", onClose) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier.size(60.dp).clip(RoundedCornerShape(20.dp)).background(s.accentSoft),
                contentAlignment = Alignment.Center,
            ) { SNIcon(SNIconName.ShieldCheck, 34.dp, s.accentDeep) }
            Text(
                "Encrypted automatically", color = s.text, fontSize = 17.sp,
                fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 10.dp),
            )
            Text(
                "Your backup is locked with the key already on this phone — there's " +
                    "nothing extra to write down. Sonar's servers only ever see ciphertext.",
                color = s.text3, fontSize = 13.sp, textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
        SNSettingsCard {
            BackupFeature(
                SNIconName.Lock, "No passphrase to lose",
                "Sealed with your existing identity key.",
            )
            BackupFeature(
                SNIconName.ImportKey, "Restores itself",
                "Sign in on a new phone and it recovers in the background.",
                divider = false,
            )
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp)) {
            SNPrimaryButton("Turn on backup", Modifier.fillMaxWidth()) { onDone(); onClose() }
            Spacer(Modifier.height(8.dp))
            SNGhostButton("Not now", Modifier.fillMaxWidth()) { onClose() }
        }
    }
}

@Composable
private fun BackupFrequencySheet(
    selected: String,
    onPick: (String) -> Unit,
    onClose: () -> Unit,
) {
    val s = sonar
    Sheet("Backup frequency", onClose) {
        listOf("daily" to "Daily", "weekly" to "Weekly", "manual" to "Manual only")
            .forEachIndexed { i, pair ->
                val (key, label) = pair
                SNXSettingsRow(
                    label = label,
                    sub = when (key) {
                        "daily" -> "Once a day, plus after changes"
                        "weekly" -> "Once a week"
                        else -> "Nothing uploads unless you ask"
                    },
                    divider = i < 2,
                    trailing = if (key == selected) {
                        { SNIcon(SNIconName.Check, 16.dp, s.accent, weight = 2.2f) }
                    } else null,
                    icon = { SNIcon(SNIconName.Data, 18.dp, it) },
                ) { onPick(key); onClose() }
            }
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp)) {
            SNGhostButton("Done", Modifier.fillMaxWidth()) { onClose() }
        }
    }
}

/**
 * Dry run: what a restore would bring back.
 *
 * The core preview never stages, commits, or opens the live store, so this is
 * safe to open mid-conversation — and the sheet says so, because a screen that
 * reads a backup is exactly where a user expects something to be overwritten.
 */
@Composable
private fun BackupDryRunSheet(onClose: () -> Unit) {
    val s = sonar
    var preview by remember { mutableStateOf<AccountBackupPreview?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        runCatching { SonarCore.previewAccountBackup() }
            .onSuccess { preview = it }
            .onFailure { err ->
                val msg = err.message.orEmpty()
                failure = if (msg.contains("account_backup_missing") ||
                    msg.contains("no account backup found")
                ) {
                    "No backup on the server for this account yet."
                } else {
                    "Could not read the backup — try again when online."
                }
            }
    }

    Sheet("Dry run · restore preview", onClose) {
        val p = preview
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "Nothing is changed on your device",
                color = s.accentDeep, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold,
            )
            Text(
                when {
                    failure != null -> "Nothing to preview"
                    p == null -> "Reading your backup…"
                    else -> "This is what would come back"
                },
                color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(top = 8.dp),
            )
            Text(
                when {
                    failure != null -> failure.orEmpty()
                    p == null ->
                        "Decrypting the index to show you exactly what a restore would bring back."
                    else -> {
                        val at = BackupFormat.lastBackup(p.uploadedAtSecs, SonarClock.nowSecs())
                        "${p.conversations.size} conversations · " +
                            "${BackupFormat.count(p.totalMessages)} messages" +
                            (if (at != null) " · from $at" else "")
                    }
                },
                color = s.text3, fontSize = 13.sp, textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 6.dp),
            )
        }

        p?.conversations?.forEach { c ->
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(30.dp).clip(RoundedCornerShape(10.dp)).background(s.surface2),
                    contentAlignment = Alignment.Center,
                ) { SNIcon(SNIconName.Lock, 15.dp, s.text2) }
                Spacer(Modifier.width(11.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        c.name, color = s.text, fontSize = 14.5.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    if (c.latestContent.isNotBlank()) {
                        Text(
                            c.latestContent, color = s.text3, fontSize = 12.5.sp,
                            maxLines = 1, modifier = Modifier.padding(top = 1.dp),
                        )
                    }
                }
                Text(
                    BackupFormat.count(c.messageCount).orEmpty(),
                    color = s.text3, fontSize = 12.5.sp,
                )
            }
        }

        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp)) {
            SNGhostButton("Close preview", Modifier.fillMaxWidth()) { onClose() }
        }
    }
}
