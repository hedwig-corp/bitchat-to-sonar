package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNSwitch
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.sonar

/**
 * The extra design glyphs (list, bell, copy, share, eye, eyeOff, importKey,
 * inbox, faceid, drive, data, arrowOut) now live in the shared icon set —
 * ui/SonarIcons.kt [SNIconName]. These aliases keep existing screen call
 * sites compiling unchanged; prefer [SNIconName]/[SNIcon] in new code.
 */
internal typealias SNXIconName = SNIconName

@Composable
internal fun SNXIcon(name: SNIconName, size: Dp, color: Color, weight: Float = 1.7f) =
    SNIcon(name, size, color, weight)

/**
 * st-row with a custom icon slot and an optional custom trailing slot — the
 * same metrics as ui/SonarComponents.SNSettingsRow (tile 34/r10, padding
 * 14×11, divider inset 60), for rows whose glyph or trail is not in the
 * shared set (bell, inbox, faceid, drive, data, arrowOut trail…).
 */
@Composable
internal fun SNXSettingsRow(
    label: String,
    tone: SNTone = SNTone.Default,
    sub: String? = null,
    value: String? = null,
    valueMono: Boolean = false,
    danger: Boolean = false,
    divider: Boolean = true,
    toggle: Boolean? = null,
    chevron: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
    icon: @Composable (Color) -> Unit,
    onClick: () -> Unit = {},
) {
    val s = sonar
    val (tileBg, tileFg) = when (tone) {
        SNTone.Cyan -> s.accentSoft to s.accentDeep
        SNTone.Gold -> s.goldSoft to s.goldDeep
        SNTone.Red -> Color(s.danger.value).copy(alpha = 0.14f) to s.danger
        SNTone.Default -> s.surface2 to s.text2
    }
    Column {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(tileBg),
                contentAlignment = Alignment.Center
            ) { icon(tileFg) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(label, color = if (danger) s.danger else s.text, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                if (sub != null) Text(sub, color = s.text3, fontSize = 12.5.sp, lineHeight = 16.sp)
            }
            if (value != null) {
                if (valueMono) Text(value, color = s.text2, style = SonarType.mono(12.0))
                else Text(value, color = s.text2, fontSize = 14.sp)
                Spacer(Modifier.width(6.dp))
            }
            when {
                toggle != null -> SNSwitch(toggle)
                trailing != null -> trailing()
                chevron -> SNIcon(SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
            }
        }
        if (divider) Box(Modifier.fillMaxWidth().padding(start = 60.dp).height(1.dp).background(s.hairline))
    }
}
