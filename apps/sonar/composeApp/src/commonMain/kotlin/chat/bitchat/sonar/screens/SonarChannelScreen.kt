package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.ui.SNBanner
import chat.bitchat.sonar.ui.SNBannerTone
import chat.bitchat.sonar.ui.SNDot
import chat.bitchat.sonar.ui.SNEmptyState
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.authorColor
import chat.bitchat.sonar.ui.sonar

@Composable
fun SonarChannelScreen(state: SonarAppState, screen: Screen.Channel) {
    val s = sonar
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()
    LaunchedEffect(state.channelMsgs.size) {
        if (state.channelMsgs.isNotEmpty()) listState.animateScrollToItem(state.channelMsgs.size - 1)
    }
    // Humanize the channel: the design NEVER shows a raw geohash as a label — use
    // the location channel's name + tier + live "N here now" count (state.presence).
    val gc = state.locationChannels.firstOrNull { it.geohash == screen.geohash }
    val isMesh = screen.geohash == "mesh"
    val name = gc?.name ?: if (isMesh) "Mesh" else "#${screen.geohash}"
    val here = state.presence(screen.geohash)
    val tier = gc?.level?.label ?: if (isMesh) "Bluetooth range" else "channel"
    val headerSub = if (here > 0) "Public · $here here now" else "Public · $tier"

    Column(Modifier.fillMaxSize().background(s.bg)) {
        // header: place tile + name + status
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 16.dp, top = 12.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, onClick = { state.back() })
            Box(
                Modifier.size(36.dp).clip(RoundedCornerShape(11.dp)).background(s.accentSoft),
                contentAlignment = Alignment.Center
            ) { SNIcon(SNIconName.Pin, 18.dp, s.accentDeep) }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(name, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNDot(s.green, 6.dp)
                    Spacer(Modifier.width(5.dp))
                    Text(headerSub, color = s.text2, fontSize = 11.5.sp)
                }
            }
            // Trailing: pin/save this channel to home (geohash channels only — Mesh
            // is always present), then people-nearby (radar) per the design.
            if (!isMesh) {
                val saved = state.isSaved(screen.geohash)
                SNIconButton(
                    if (saved) SNIconName.BookmarkFill else SNIconName.Bookmark,
                    tint = if (saved) s.accent else s.text2,
                    onClick = { state.toggleSaved(screen.geohash) }
                )
            }
            SNIconButton(SNIconName.Rings, onClick = { state.push(Screen.Nearby) })
        }

        SNBanner(
            icon = SNIconName.People, tone = SNBannerTone.Public,
            bold = "Public channel", rest = " — anyone nearby can read"
        )

        if (state.channelMsgs.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (isMesh) {
                    SNEmptyState(
                        icon = SNIconName.Mesh, iconSize = 26.dp,
                        title = "Bluetooth mesh",
                        desc = "Messages here reach everyone in Bluetooth range — no internet needed. Say hi."
                    )
                } else {
                    SNEmptyState(
                        icon = SNIconName.Pin, iconSize = 26.dp,
                        title = "Quiet in $name right now",
                        desc = if (here > 0) "$here ${if (here == 1) "person is" else "people are"} in range of this channel today. Say hi."
                               else "Be the first to say something in $name."
                    )
                }
            }
        } else {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                state = listState,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
            ) {
                items(state.channelMsgs, key = { it.id }) { m ->
                    ChannelBubble(m) {
                        if (!m.mine) state.openGeoDm(screen.geohash, m.senderPubkey, m.author)
                    }
                }
            }
        }

        // composer
        Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(22.dp)).background(s.surface2)
                    .padding(horizontal = 16.dp, vertical = 12.dp)
            ) {
                if (draft.isEmpty()) Text("Message $name", color = s.text3, fontSize = 16.sp)
                BasicTextField(
                    value = draft, onValueChange = { draft = it },
                    textStyle = TextStyle(color = s.text, fontSize = 16.sp),
                    cursorBrush = SolidColor(s.accent),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier.size(46.dp).clip(CircleShape).background(s.netFill)
                    .clickable { state.sendChannelMsg(screen.geohash, draft); draft = "" },
                contentAlignment = Alignment.Center
            ) { Text("↑", color = s.onNet, fontSize = 20.sp, fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun ChannelBubble(m: SonarChannelMsg, onTapAuthor: () -> Unit) {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        if (!m.mine) {
            Text(
                m.author, color = authorColor(m.author, s.isDark),
                fontSize = 12.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(start = 12.dp, bottom = 3.dp).clickable(onClick = onTapAuthor)
            )
        }
        Box(
            Modifier.clip(RoundedCornerShape(18.dp))
                .background(if (m.mine) s.netFill else s.bubbleOther)
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            Text(m.content, color = if (m.mine) s.onNet else s.text, fontSize = 16.sp)
        }
    }
}
