package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ToastBar
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SNSettingsCard
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SNTrail
import chat.bitchat.sonar.ui.sonar
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.auto_backup
import chat.bitchat.sonar.resources.backing_up_chats
import chat.bitchat.sonar.resources.backup_chats
import chat.bitchat.sonar.resources.chat_backup
import chat.bitchat.sonar.resources.encrypted_cloud_backup_recover_chats
import chat.bitchat.sonar.resources.encrypted_cloud_backup_when_chats_change
import chat.bitchat.sonar.resources.no_backup_yet
import chat.bitchat.sonar.resources.sanity_check
import org.jetbrains.compose.resources.stringResource

@Composable
fun SonarBackupScreen(state: SonarAppState) {
    val s = sonar
    LaunchedEffect(Unit) {
        state.discloseAutoBackup()
        state.refreshBackupPolicy()
    }
    // Subscribe to policy / progress for recomposition.
    state.autoBackupEnabled
    state.autoBackupStatusLine
    state.backupInProgress
    val checks = state.backupSanityChecks

    Column(Modifier.fillMaxSize().background(s.bg)) {
        SNNavHeader(
            stringResource(Res.string.chat_backup),
            hairline = false,
            onBack = { state.back() },
        )

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(bottom = 40.dp),
        ) {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)
                    .clip(RoundedCornerShape(20.dp)).background(s.accentSoft)
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                SNIcon(SNIconName.ShieldCheck, 32.dp, s.accentDeep)
                Spacer(Modifier.height(10.dp))
                Text(
                    state.autoBackupStatusLine.ifBlank {
                        stringResource(Res.string.no_backup_yet)
                    },
                    color = s.text,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    stringResource(Res.string.encrypted_cloud_backup_when_chats_change),
                    color = s.text2,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 8.dp),
                )
            }

            SNSectionLabel(stringResource(Res.string.auto_backup))
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.ShieldCheck,
                    tone = SNTone.Cyan,
                    label = stringResource(Res.string.auto_backup),
                    sub = stringResource(Res.string.encrypted_cloud_backup_when_chats_change),
                    toggle = state.autoBackupEnabled,
                ) { state.updateAutoBackupEnabled(!state.autoBackupEnabled) }
            }

            SNSectionLabel(stringResource(Res.string.sanity_check))
            SNSettingsCard {
                checks.forEachIndexed { index, item ->
                    SNSettingsRow(
                        icon = if (item.ok) SNIconName.Check else SNIconName.Info,
                        tone = if (item.ok) SNTone.Cyan else SNTone.Default,
                        label = item.title,
                        sub = item.detail,
                        value = if (item.ok) "OK" else "Check",
                        trail = SNTrail.None,
                        divider = index < checks.lastIndex,
                    ) {}
                }
                if (checks.isEmpty()) {
                    SNSettingsRow(
                        icon = SNIconName.Info,
                        label = stringResource(Res.string.sanity_check),
                        sub = "Loading…",
                        trail = SNTrail.None,
                        divider = false,
                    ) {}
                }
            }

            SNSectionLabel(stringResource(Res.string.backup_chats))
            SNSettingsCard {
                SNSettingsRow(
                    icon = SNIconName.ShieldCheck,
                    tone = SNTone.Cyan,
                    label = if (state.backupInProgress) {
                        stringResource(Res.string.backing_up_chats)
                    } else {
                        stringResource(Res.string.backup_chats)
                    },
                    sub = stringResource(Res.string.encrypted_cloud_backup_recover_chats),
                    trail = if (state.backupInProgress) SNTrail.None else SNTrail.Chevron,
                    divider = false,
                ) {
                    if (!state.backupInProgress) state.backupAccountNow()
                }
            }
        }
    }

    state.toast?.let { ToastBar(it) { state.toast = null } }
}
