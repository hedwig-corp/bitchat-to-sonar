package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarGifItem
import chat.bitchat.sonar.ui.SNEmptyState
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.sonar

private enum class PickerTab { Emoji, Gif, Sticker }

private val frequentEmojis = listOf("👍", "❤️", "😂", "🔥", "🙏", "👏", "🎉", "👀", "💯", "⚡")

private data class EmojiCategory(val name: String, val emojis: List<String>)

private val emojiCategories = listOf(
    EmojiCategory("Smileys", listOf(
        "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃",
        "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😙",
        "🥲", "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭", "🫢",
        "🤫", "🤔", "🫡", "🤐", "🤨", "😐", "😑", "😶", "🫥", "😏",
        "😒", "🙄", "😬", "🤥", "😌", "😔", "😪", "🤤", "😴", "😷",
    )),
    EmojiCategory("People", listOf(
        "👋", "🤚", "🖐️", "✋", "🖖", "🫱", "🫲", "🫳", "🫴", "👌",
        "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "🤙", "👈", "👉",
        "👆", "🖕", "👇", "☝️", "🫵", "👍", "👎", "✊", "👊", "🤛",
        "🤜", "👏", "🙌", "🫶", "👐", "🤲", "🤝", "🙏", "✍️", "💅",
        "🤳", "💪", "🦾", "🦿", "🦵", "🦶", "👂", "🦻", "👃", "🧠",
    )),
    EmojiCategory("Animals", listOf(
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐻‍❄️", "🐨",
        "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐒",
        "🐔", "🐧", "🐦", "🐤", "🐣", "🐥", "🦆", "🦅", "🦉", "🦇",
        "🐺", "🐗", "🐴", "🦄", "🐝", "🪱", "🐛", "🦋", "🐌", "🐞",
        "🐜", "🪰", "🪲", "🪳", "🦟", "🦗", "🕷️", "🐢", "🐍", "🦎",
    )),
    EmojiCategory("Food", listOf(
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐",
        "🍈", "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑",
        "🥦", "🥬", "🥒", "🌶️", "🫑", "🌽", "🥕", "🫒", "🧄", "🧅",
        "🥔", "🍠", "🥐", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🧈",
        "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🌭", "🍔", "🍟", "🍕",
    )),
    EmojiCategory("Travel", listOf(
        "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑", "🚒", "🚐",
        "🛻", "🚚", "🚛", "🚜", "🏍️", "🛵", "🚲", "🛴", "🛹", "🛼",
        "✈️", "🛫", "🛬", "🪂", "💺", "🚀", "🛸", "🚁", "⛵", "🚤",
        "🗺️", "🗻", "🏔️", "⛰️", "🌋", "🏕️", "🏖️", "🏜️", "🏝️", "🏞️",
        "🌅", "🌄", "🌠", "🎇", "🎆", "🌇", "🌆", "🏙️", "🌃", "🌌",
    )),
    EmojiCategory("Activities", listOf(
        "⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱",
        "🪀", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🪃", "🥅", "⛳",
        "🪁", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹", "🛼", "⛸️",
        "🥌", "🎿", "⛷️", "🏂", "🪂", "🏋️", "🤸", "🤺", "⛹️", "🤾",
        "🏌️", "🏇", "🧘", "🏄", "🏊", "🤽", "🚣", "🧗", "🚴", "🚵",
    )),
    EmojiCategory("Objects", listOf(
        "⌚", "📱", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "🖲️", "🕹️", "🗜️",
        "💾", "💿", "📀", "📼", "📷", "📸", "📹", "🎥", "📽️", "🎞️",
        "📞", "☎️", "📟", "📠", "📺", "📻", "🎙️", "🎚️", "🎛️", "🧭",
        "⏱️", "⏲️", "⏰", "🕰️", "⌛", "⏳", "📡", "🔋", "🪫", "🔌",
        "💡", "🔦", "🕯️", "🪔", "🧯", "🗑️", "🛢️", "💸", "💵", "💴",
    )),
    EmojiCategory("Symbols", listOf(
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
        "❤️‍🔥", "❤️‍🩹", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟",
        "☮️", "✝️", "☪️", "🕉️", "☸️", "✡️", "🔯", "🕎", "☯️", "☦️",
        "♈", "♉", "♊", "♋", "♌", "♍", "♎", "♏", "♐", "♑",
        "♒", "♓", "⛎", "🔀", "🔁", "🔂", "▶️", "⏩", "⏭️", "⏯️",
    )),
    EmojiCategory("Flags", listOf(
        "🏁", "🚩", "🎌", "🏴", "🏳️", "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️", "🇺🇸", "🇬🇧",
        "🇫🇷", "🇩🇪", "🇯🇵", "🇰🇷", "🇨🇳", "🇮🇹", "🇪🇸", "🇧🇷", "🇮🇳", "🇷🇺",
        "🇨🇦", "🇦🇺", "🇲🇽", "🇦🇷", "🇨🇴", "🇳🇬", "🇿🇦", "🇪🇬", "🇹🇷", "🇸🇦",
    )),
)

@Composable
fun SonarEmojiPicker(
    onEmoji: (String) -> Unit,
    onGif: (SonarGifItem) -> Unit,
    onClose: () -> Unit,
) {
    val s = sonar
    var tab by remember { mutableStateOf(PickerTab.Emoji) }

    Column(
        Modifier
            .fillMaxWidth()
            .height(320.dp)
            .clip(RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp))
            .background(s.surface)
    ) {
        Box(
            Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 6.dp),
            contentAlignment = Alignment.Center
        ) {
            Box(
                Modifier
                    .width(40.dp)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(s.surface2)
            )
        }

        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            PickerTabPill(SNIconName.Smile, tab == PickerTab.Emoji) { tab = PickerTab.Emoji }
            PickerTabPill(SNIconName.Gif, tab == PickerTab.Gif) { tab = PickerTab.Gif }
            PickerTabPill(SNIconName.Sticker, tab == PickerTab.Sticker) { tab = PickerTab.Sticker }
        }

        when (tab) {
            PickerTab.Emoji -> EmojiTabContent(onEmoji)
            PickerTab.Gif -> GifTabContent()
            PickerTab.Sticker -> StickerTabContent()
        }
    }
}

@Composable
private fun PickerTabPill(icon: SNIconName, selected: Boolean, onClick: () -> Unit) {
    val s = sonar
    Box(
        Modifier
            .height(40.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) s.accentFill else s.surface2)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center
    ) {
        SNIcon(icon, 20.dp, if (selected) s.onAccent else s.text2, weight = 2f)
    }
}

@Composable
private fun ColumnScope.EmojiTabContent(onEmoji: (String) -> Unit) {
    val s = sonar
    var search by remember { mutableStateOf("") }
    var selectedCategory by remember { mutableStateOf(0) }

    SearchField(search, "Search emoji") { search = it }

    if (search.isBlank()) {
        Row(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 14.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            emojiCategories.forEachIndexed { index, cat ->
                CategoryLabel(cat.name, index == selectedCategory) { selectedCategory = index }
            }
        }
    }

    val displayEmojis = if (search.isBlank()) {
        emojiCategories[selectedCategory].emojis
    } else {
        emojiCategories.flatMap { it.emojis }
    }

    LazyVerticalGrid(
        columns = GridCells.Fixed(8),
        modifier = Modifier.fillMaxWidth().weight(1f).padding(horizontal = 6.dp),
    ) {
        if (search.isBlank() && selectedCategory == 0) {
            item(span = { GridItemSpan(8) }) {
                Text(
                    "FREQUENTLY USED",
                    color = s.text3,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp,
                    modifier = Modifier.padding(start = 8.dp, top = 6.dp, bottom = 2.dp)
                )
            }
            items(frequentEmojis) { emoji ->
                EmojiCell(emoji, onEmoji)
            }
            item(span = { GridItemSpan(8) }) {
                Text(
                    emojiCategories[0].name.uppercase(),
                    color = s.text3,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp,
                    modifier = Modifier.padding(start = 8.dp, top = 8.dp, bottom = 2.dp)
                )
            }
        }
        items(displayEmojis) { emoji ->
            EmojiCell(emoji, onEmoji)
        }
    }
}

@Composable
private fun EmojiCell(emoji: String, onEmoji: (String) -> Unit) {
    Box(
        Modifier
            .size(42.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable { onEmoji(emoji) },
        contentAlignment = Alignment.Center
    ) {
        Text(emoji, fontSize = 24.sp)
    }
}

@Composable
private fun CategoryLabel(name: String, selected: Boolean, onClick: () -> Unit) {
    val s = sonar
    Column(
        Modifier.clickable(onClick = onClick).padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            name,
            color = if (selected) s.accent else s.text3,
            fontSize = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal
        )
        Spacer(Modifier.height(3.dp))
        Box(
            Modifier
                .width(24.dp)
                .height(2.dp)
                .clip(RoundedCornerShape(1.dp))
                .background(if (selected) s.accent else s.surface)
        )
    }
}

@Composable
private fun ColumnScope.GifTabContent() {
    val s = sonar
    var search by remember { mutableStateOf("") }

    SearchField(search, "Search GIFs") { search = it }

    SNSectionLabel("Trending")

    Column(
        Modifier
            .fillMaxWidth()
            .weight(1f)
            .padding(horizontal = 14.dp)
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                repeat(3) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(120.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(s.surface2)
                    )
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                repeat(3) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(120.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(s.surface2)
                    )
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        SNIcon(SNIconName.Gif, 28.dp, s.text3)
        Spacer(Modifier.height(6.dp))
        Text(
            "GIF search coming soon",
            color = s.text2,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium
        )
        Text(
            "Nostr relay integration in progress",
            color = s.text3,
            fontSize = 12.sp
        )

        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun ColumnScope.StickerTabContent() {
    val s = sonar

    Column(
        Modifier
            .fillMaxWidth()
            .weight(1f)
            .verticalScroll(rememberScrollState())
    ) {
        SNSectionLabel("Your stickers")

        SNEmptyState(
            icon = SNIconName.Sticker,
            title = "No sticker packs yet",
            desc = "Add sticker packs to express yourself"
        )

        Spacer(Modifier.height(16.dp))

        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(s.surface2)
                .clickable { }
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier
                    .size(34.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(s.accentSoft),
                contentAlignment = Alignment.Center
            ) {
                SNIcon(SNIconName.Sticker, 18.dp, s.accentDeep)
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    "Add sticker pack",
                    color = s.text,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    "Browse and install sticker packs",
                    color = s.text3,
                    fontSize = 12.5.sp
                )
            }
            SNIcon(SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
        }

        SNSectionLabel("Popular stickers")

        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            repeat(4) {
                Box(
                    Modifier
                        .weight(1f)
                        .height(72.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(s.surface2)
                )
            }
        }

        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun SearchField(value: String, placeholder: String, onValueChange: (String) -> Unit) {
    val s = sonar
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(s.surface2)
            .padding(horizontal = 14.dp, vertical = 10.dp)
    ) {
        if (value.isEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SNIcon(SNIconName.Search, 15.dp, s.text3, weight = 2f)
                Spacer(Modifier.width(8.dp))
                Text(placeholder, color = s.text3, fontSize = 15.sp)
            }
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = TextStyle(color = s.text, fontSize = 15.sp),
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(start = 23.dp)
        )
    }
}
