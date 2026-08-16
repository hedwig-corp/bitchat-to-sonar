package chat.bitchat.sonar.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
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
import androidx.compose.material3.LocalTextStyle
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAccountRestoreException
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.anyone_with_this_key_controls_your
import chat.bitchat.sonar.resources.bluetooth_finds_people_around_you_even
import chat.bitchat.sonar.resources.continue_
import chat.bitchat.sonar.resources.create_a_new_identity
import chat.bitchat.sonar.resources.direct_messages_are_end_to_end
import chat.bitchat.sonar.resources.friends_can_verify_this_fingerprint_in
import chat.bitchat.sonar.resources.generating
import chat.bitchat.sonar.resources.get_started
import chat.bitchat.sonar.resources.it_s_just_what_people_see_change_it
import chat.bitchat.sonar.resources.messages_travel_encrypted_over_the_open
import chat.bitchat.sonar.resources.nickname
import chat.bitchat.sonar.resources.no_account_was_created_anywhere_your
import chat.bitchat.sonar.resources.no_signup_your_identity_is_a_private
import chat.bitchat.sonar.resources.nsec1
import chat.bitchat.sonar.resources.out_of_range_still_reachable
import chat.bitchat.sonar.resources.paste_key
import chat.bitchat.sonar.resources.paste_your_nsec_private_key_to_bring
import chat.bitchat.sonar.resources.pick_a_nickname
import chat.bitchat.sonar.resources.private_by_design
import chat.bitchat.sonar.resources.restore_account
import chat.bitchat.sonar.resources.restoring
import chat.bitchat.sonar.resources.sense_who_s_nearby_before_you_see_them
import chat.bitchat.sonar.resources.sonar_connects_phones_directly_no_phone
import chat.bitchat.sonar.resources.start_chatting
import chat.bitchat.sonar.resources.surprise_me
import chat.bitchat.sonar.resources.that_key_couldn_t_be_imported_check_you
import chat.bitchat.sonar.resources.works_without_internet
import chat.bitchat.sonar.resources.you_re_in
import chat.bitchat.sonar.resources.your_key_fingerprint_2
import chat.bitchat.sonar.ui.SNFingerprintCard
import chat.bitchat.sonar.ui.SNGhostButton
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar
import org.jetbrains.compose.resources.stringResource

private val SUGGESTIONS = listOf(
    "quietfox", "tram12", "lakeswim", "verdigris", "morningstatic", "papercrane", "northpine", "softsignal"
)

@Composable
fun SonarOnboardingScreen(state: SonarAppState) {
    val s = sonar
    var step by remember { mutableStateOf(0) }
    var nick by remember { mutableStateOf("") }
    var restoring by remember { mutableStateOf(false) }
    var nsec by remember { mutableStateOf("") }
    var restoreError by remember { mutableStateOf<String?>(null) }
    var restoreInFlight by remember { mutableStateOf(false) }
    val trimmed = nick.trim()
    val can = trimmed.length >= 2
    val nsecOk = nsec.trim().matches(Regex("^nsec1[0-9a-z]{20,}$"))
    val clipboard = LocalClipboardManager.current
    val restoreFailureFallback =
        stringResource(Res.string.that_key_couldn_t_be_imported_check_you)

    Column(
        Modifier.fillMaxSize().background(s.bg)
            .padding(start = 28.dp, end = 28.dp, top = 10.dp, bottom = 12.dp)
    ) {
        // Top bar (back)
        Box(Modifier.fillMaxWidth().height(40.dp)) {
            if (step > 0 || restoring) {
                SNIconButton(SNIconName.Back, onClick = {
                    if (restoring) {
                        restoring = false
                        restoreError = null
                    } else {
                        step -= 1
                    }
                })
            }
        }

        AnimatedContent(
            targetState = if (restoring) -1 else step,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            modifier = Modifier.weight(1f)
        ) { st ->
            when (st) {
                -1 -> StepRestore(
                    nsec = nsec,
                    error = restoreError,
                    onChange = { nsec = it },
                    onPaste = { clipboard.getText()?.text?.let { nsec = it.trim() } },
                )
                0 -> StepIntro()
                1 -> StepNickname(nick, trimmed) { nick = it.take(20) }
                else -> StepDone(trimmed, state.fingerprint())
            }
        }

        // Footer
        Column(Modifier.padding(top = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            if (!restoring) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    repeat(3) { i ->
                        Box(
                            Modifier.size(7.dp).clip(CircleShape)
                                .background(if (step == i) s.accent else s.hairline)
                        )
                    }
                }
                Spacer(Modifier.height(16.dp))
            }
            if (restoring) {
                SNPrimaryButton(
                    if (restoreInFlight) stringResource(Res.string.restoring) else stringResource(Res.string.restore_account),
                    disabled = !nsecOk || restoreInFlight,
                ) {
                    val key = nsec.trim()
                    restoreInFlight = true
                    restoreError = null
                    state.restoreAccount(key) { result ->
                        restoreInFlight = false
                        result.exceptionOrNull()?.let { failure ->
                            restoreError = (failure as? SonarAccountRestoreException)?.message
                                ?: restoreFailureFallback
                        }
                    }
                }
                SNGhostButton(stringResource(Res.string.create_a_new_identity)) {
                    restoring = false
                    restoreError = null
                    nsec = ""
                }
            } else {
                when (step) {
                    0 -> {
                        // Keep both first-run paths in one bounded row. A stacked
                        // secondary action was clipped below the viewport on the
                        // API 36 medium-phone layout, making restore undiscoverable.
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            SNPrimaryButton(stringResource(Res.string.get_started), Modifier.weight(1f)) { step = 1 }
                            Box(
                                Modifier.weight(1f).height(52.dp)
                                    .clip(RoundedCornerShape(15.dp)).background(s.accentSoft)
                                    .clickable {
                                        nsec = ""
                                        restoreError = null
                                        restoring = true
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    stringResource(Res.string.restore_account),
                                    color = s.accentDeep,
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                    }
                    1 -> SNPrimaryButton(stringResource(Res.string.continue_), disabled = !can) { if (can) step = 2 }
                    else -> SNPrimaryButton(stringResource(Res.string.start_chatting)) { state.completeOnboarding(trimmed) }
                }
            }
        }
    }
}

/**
 * A step keeps its centred layout while it fits, and scrolls once it does not
 * (short screens, large font scales, keyboard up). The footer stays put.
 */
@Composable
private fun StepBody(content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val viewport = maxHeight
        Column(
            Modifier.fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .heightIn(min = viewport),
            verticalArrangement = Arrangement.Center,
            content = content,
        )
    }
}

@Composable
private fun StepIntro() {
    val s = sonar
    StepBody {
        Box(
            Modifier.size(74.dp).clip(RoundedCornerShape(23.dp)).background(s.accentFill),
            contentAlignment = Alignment.Center
        ) { SNIcon(SNIconName.Rings, 40.dp, s.onAccent, weight = 1.5f) }
        Spacer(Modifier.height(28.dp))
        Text(
            stringResource(Res.string.sense_who_s_nearby_before_you_see_them),
            color = s.text, fontSize = 30.sp, fontWeight = FontWeight.Black, lineHeight = 34.sp
        )
        Spacer(Modifier.height(10.dp))
        Text(
            stringResource(Res.string.sonar_connects_phones_directly_no_phone),
            color = s.text2, fontSize = 16.sp, lineHeight = 21.sp
        )
        Spacer(Modifier.height(22.dp))
        FeatureRow(SNIconName.Mesh, stringResource(Res.string.works_without_internet), stringResource(Res.string.bluetooth_finds_people_around_you_even))
        FeatureRow(SNIconName.Globe, stringResource(Res.string.out_of_range_still_reachable), stringResource(Res.string.messages_travel_encrypted_over_the_open))
        FeatureRow(SNIconName.Lock, stringResource(Res.string.private_by_design), stringResource(Res.string.direct_messages_are_end_to_end))
    }
}

@Composable
private fun FeatureRow(icon: SNIconName, title: String, desc: String) {
    val s = sonar
    Row(Modifier.fillMaxWidth().padding(vertical = 11.dp)) {
        Box(
            Modifier.size(40.dp).clip(RoundedCornerShape(13.dp)).background(s.accentSoft),
            contentAlignment = Alignment.Center
        ) { SNIcon(icon, 20.dp, s.accentDeep) }
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Text(desc, color = s.text2, fontSize = 13.5.sp, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun StepNickname(nick: String, trimmed: String, onChange: (String) -> Unit) {
    val s = sonar
    StepBody {
        Text(stringResource(Res.string.pick_a_nickname), color = s.text, fontSize = 30.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
        Text(stringResource(Res.string.it_s_just_what_people_see_change_it), color = s.text2, fontSize = 16.sp, lineHeight = 21.sp)
        Spacer(Modifier.height(22.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            SonarAvatar(trimmed.ifEmpty { "?" }, 72.dp)
            Spacer(Modifier.width(16.dp))
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(16.dp)).background(s.surface2)
                    .padding(horizontal = 16.dp, vertical = 15.dp)
            ) {
                if (nick.isEmpty()) Text(stringResource(Res.string.nickname), color = s.text3, fontSize = 21.sp, fontWeight = FontWeight.Medium)
                BasicTextField(
                    value = nick,
                    onValueChange = onChange,
                    singleLine = true,
                    textStyle = TextStyle(color = s.text, fontSize = 21.sp, fontWeight = FontWeight.Bold),
                    cursorBrush = SolidColor(s.accent),
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }
        Spacer(Modifier.height(18.dp))
        Row(
            Modifier.clip(CircleShape).background(s.accentSoft).clickable {
                onChange(SUGGESTIONS[(nick.hashCode() and 0x7fffffff) % SUGGESTIONS.size])
            }.padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIcon(SNIconName.Dice, 16.dp, s.accentDeep, weight = 2f)
            Spacer(Modifier.width(7.dp))
            Text(stringResource(Res.string.surprise_me), color = s.accentDeep, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(18.dp))
        Text(
            stringResource(Res.string.no_signup_your_identity_is_a_private),
            color = s.text3, fontSize = 13.sp, lineHeight = 17.sp
        )
    }
}

@Composable
private fun StepRestore(
    nsec: String,
    error: String?,
    onChange: (String) -> Unit,
    onPaste: () -> Unit,
) {
    val s = sonar
    StepBody {
        Text(stringResource(Res.string.restore_account), color = s.text, fontSize = 30.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
        Text(
            stringResource(Res.string.paste_your_nsec_private_key_to_bring),
            color = s.text2, fontSize = 16.sp, lineHeight = 21.sp,
        )
        Spacer(Modifier.height(22.dp))
        Box(
            Modifier.fillMaxWidth().heightIn(min = 116.dp).clip(RoundedCornerShape(16.dp)).background(s.surface2)
                .padding(horizontal = 16.dp, vertical = 14.dp)
        ) {
            if (nsec.isEmpty()) Text(stringResource(Res.string.nsec1), color = s.text3, fontSize = 16.sp)
            BasicTextField(
                value = nsec,
                onValueChange = { onChange(it.trim()) },
                textStyle = TextStyle(color = s.text, fontSize = 15.sp, lineHeight = 20.sp),
                cursorBrush = SolidColor(s.accent),
                modifier = Modifier.fillMaxWidth()
            )
        }
        Spacer(Modifier.height(12.dp))
        Row(
            Modifier.clip(CircleShape).background(s.accentSoft).clickable(onClick = onPaste)
                .padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIcon(SNIconName.Key, 16.dp, s.accentDeep, weight = 2f)
            Spacer(Modifier.width(7.dp))
            Text(stringResource(Res.string.paste_key), color = s.accentDeep, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(18.dp))
        Text(stringResource(Res.string.anyone_with_this_key_controls_your), color = s.text3, fontSize = 13.sp, lineHeight = 17.sp)
        if (error != null) {
            Spacer(Modifier.height(14.dp))
            Text(error, color = s.danger, fontSize = 13.sp, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun StepDone(nick: String, fingerprint: String) {
    val s = sonar
    val generatingLabel = stringResource(Res.string.generating)
    StepBody {
        SonarAvatar(nick.ifEmpty { "?" }, 92.dp)
        Spacer(Modifier.height(22.dp))
        Text(stringResource(Res.string.you_re_in, nick), color = s.text, fontSize = 30.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
        Text(stringResource(Res.string.no_account_was_created_anywhere_your), color = s.text2, fontSize = 16.sp, lineHeight = 21.sp)
        Spacer(Modifier.height(24.dp))
        SNFingerprintCard(
            stringResource(Res.string.your_key_fingerprint_2),
            fingerprint.ifEmpty { generatingLabel },
        )
        Spacer(Modifier.height(18.dp))
        Text(stringResource(Res.string.friends_can_verify_this_fingerprint_in), color = s.text3, fontSize = 13.sp, lineHeight = 17.sp)
    }
}
