package chat.bitchat.sonar.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.ui.SNBanner
import chat.bitchat.sonar.ui.SNBannerTone
import chat.bitchat.sonar.ui.SNGhostButton
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNNavHeader
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SNSettingsCard
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SNTrail
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar

@Composable
fun SonarGroupInfoScreen(state: SonarAppState, screen: Screen.GroupInfo) {
    val s = sonar
    val chatId = screen.chatId
    val chat = state.chats.firstOrNull { it.id == chatId }
    val groupName = chat?.let { state.chatTitle(it) } ?: "Group chat"
    val members = state.allGroupMemberContacts(chatId)

    var showAddPeople by remember { mutableStateOf(false) }
    var addDraft by remember { mutableStateOf("") }
    var showLeaveSheet by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().background(s.bg)) {
            SNNavHeader("Group info", hairline = false, onBack = { state.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

                // ── Group hero (centered) ──
                Column(
                    Modifier.fillMaxWidth().padding(top = 14.dp, start = 28.dp, end = 28.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    SonarAvatar(groupName, 96.dp)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        groupName,
                        color = s.text, fontSize = 24.sp, fontWeight = FontWeight.Black
                    )
                    Spacer(Modifier.height(6.dp))
                    Box(
                        Modifier.clip(CircleShape).background(s.surface2)
                            .padding(horizontal = 11.dp, vertical = 4.dp)
                    ) {
                        Text(
                            "${members.size} members · End-to-end encrypted",
                            color = s.text2, fontSize = 12.5.sp
                        )
                    }
                }

                Spacer(Modifier.height(10.dp))

                // ── Encryption banner ──
                SNBanner(
                    icon = SNIconName.Lock,
                    tone = SNBannerTone.Enc,
                    bold = "End-to-end encrypted",
                    rest = " — only group members can read this"
                )

                // ── Members section ──
                SNSectionLabel("Members (${members.size})")

                // Add member action row
                Row(
                    Modifier.fillMaxWidth()
                        .clickable { showAddPeople = !showAddPeople }
                        .padding(horizontal = 14.dp, vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(s.accentSoft),
                        contentAlignment = Alignment.Center
                    ) { SNIcon(SNIconName.Plus, 18.dp, s.accentDeep) }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text("Add people", color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
                        Text("Invite via npub or local contacts", color = s.text2, fontSize = 12.5.sp, lineHeight = 16.sp)
                    }
                    SNIcon(SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
                }

                // ── Add member inline section ──
                AnimatedVisibility(visible = showAddPeople) {
                    Column(
                        Modifier.fillMaxWidth().padding(horizontal = 14.dp).padding(bottom = 10.dp)
                            .clip(RoundedCornerShape(14.dp)).background(s.surface)
                            .padding(14.dp)
                    ) {
                        Box(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(s.surface2)
                                .padding(horizontal = 12.dp, vertical = 11.dp)
                        ) {
                            if (addDraft.isEmpty()) Text(
                                "npub1… npub1…",
                                color = s.text3, fontSize = 14.sp
                            )
                            BasicTextField(
                                value = addDraft,
                                onValueChange = { addDraft = it },
                                singleLine = false,
                                textStyle = TextStyle(color = s.text, fontSize = 14.sp),
                                cursorBrush = SolidColor(s.accent),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        Spacer(Modifier.height(10.dp))
                        SNPrimaryButton(
                            "Add people",
                            disabled = parsedNpubs(addDraft).isEmpty()
                        ) {
                            val npubs = parsedNpubs(addDraft)
                            if (npubs.isNotEmpty()) {
                                state.addGroupMembers(chatId, npubs)
                                addDraft = ""
                                showAddPeople = false
                            }
                        }
                    }
                }

                // ── Member list ──
                Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp)) {
                    members.forEachIndexed { index, member ->
                        val isYou = member.npub == state.npub
                        val isCreator = index == 0
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .then(
                                    if (!isYou) Modifier.clickable {
                                        state.push(Screen.ContactProfile(member.npub, member.title))
                                    } else Modifier
                                )
                                .padding(horizontal = 6.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            SonarAvatar(member.title, 38.dp)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    member.title,
                                    color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold,
                                    maxLines = 1
                                )
                                if (member.subtitle.isNotBlank()) {
                                    Text(
                                        member.subtitle,
                                        color = s.text2, fontSize = 12.5.sp, lineHeight = 16.sp,
                                        maxLines = 1
                                    )
                                }
                            }
                            if (isYou) {
                                Box(
                                    Modifier.clip(CircleShape).background(s.accentSoft)
                                        .padding(horizontal = 10.dp, vertical = 3.dp)
                                ) {
                                    Text(
                                        "You", color = s.accentDeep,
                                        fontSize = 12.sp, fontWeight = FontWeight.SemiBold
                                    )
                                }
                            }
                            if (isCreator) {
                                Spacer(Modifier.width(6.dp))
                                SNIcon(SNIconName.Crown, 16.dp, s.goldDeep, weight = 1.7f)
                            }
                        }
                    }
                }

                // ── Group actions section ──
                SNSectionLabel("Group")
                SNSettingsCard {
                    SNSettingsRow(
                        icon = SNIconName.Info, tone = SNTone.Default,
                        label = "Notifications", trail = SNTrail.Chevron
                    ) { state.toast = "Coming soon" }
                    SNSettingsRow(
                        icon = SNIconName.Camera, tone = SNTone.Default,
                        label = "Shared media", trail = SNTrail.Chevron, divider = false
                    ) { state.toast = "Coming soon" }
                }

                // ── Danger zone ──
                Spacer(Modifier.height(8.dp))
                SNSectionLabel("Danger zone")
                SNSettingsCard {
                    SNSettingsRow(
                        icon = SNIconName.Leave, tone = SNTone.Red,
                        label = "Leave group", danger = true,
                        trail = SNTrail.None, divider = false
                    ) { showLeaveSheet = true }
                }

                Spacer(Modifier.height(40.dp))
            }
        }

        // ── Leave group confirmation sheet ──
        if (showLeaveSheet) {
            Box(
                Modifier.fillMaxSize().background(s.scrim)
                    .clickable(onClick = { showLeaveSheet = false }),
                contentAlignment = Alignment.BottomCenter
            ) {
                Surface(
                    color = s.surface,
                    shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)
                ) {
                    Column(Modifier.fillMaxWidth().padding(20.dp)) {
                        Text(
                            "Leave this group?",
                            color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "You’ll no longer receive messages from this group.",
                            color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                        )
                        Spacer(Modifier.height(16.dp))
                        SNPrimaryButton("Leave group", net = false) {
                            state.deleteMarmotChat(chatId)
                            state.back()
                            state.back()
                        }
                        Spacer(Modifier.height(8.dp))
                        SNGhostButton("Cancel") { showLeaveSheet = false }
                    }
                }
            }
        }
    }
}

/** Split whitespace/comma-separated input and keep only valid npub1 keys. */
private fun parsedNpubs(input: String): List<String> =
    input.split(Regex("[\\s,]+"))
        .map { it.trim() }
        .filter { it.startsWith("npub1") && it.length > 10 }
        .distinct()
