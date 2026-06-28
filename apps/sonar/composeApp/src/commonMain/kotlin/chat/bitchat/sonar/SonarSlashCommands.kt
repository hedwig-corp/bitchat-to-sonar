package chat.bitchat.sonar

internal enum class SonarSlashCommand(
    val canonical: String,
    val description: String,
    val aliases: Set<String> = emptySet(),
    val needsArgument: Boolean = true,
) {
    Message("msg", "Message someone", aliases = setOf("m")),
    Who("who", "See who's nearby", aliases = setOf("w"), needsArgument = false),
    Clear("clear", "Clear this timeline", needsArgument = false),
    Hug("hug", "Send a hug"),
    Slap("slap", "Classic IRC slap"),
    Favorite("fav", "Add favorite"),
    Unfavorite("unfav", "Remove favorite"),
    Block("block", "Block someone"),
    Unblock("unblock", "Unblock someone"),
}

internal data class ParsedSlashCommand(
    val command: SonarSlashCommand,
    val args: String,
)

internal object SonarSlashCommands {
    val hints: List<SonarSlashCommand> = listOf(
        SonarSlashCommand.Message,
        SonarSlashCommand.Who,
        SonarSlashCommand.Clear,
        SonarSlashCommand.Hug,
        SonarSlashCommand.Slap,
        SonarSlashCommand.Favorite,
        SonarSlashCommand.Unfavorite,
        SonarSlashCommand.Block,
        SonarSlashCommand.Unblock,
    )

    private val byName: Map<String, SonarSlashCommand> =
        hints.flatMap { command ->
            (command.aliases + command.canonical).map { it to command }
        }.toMap()

    fun parse(raw: String): ParsedSlashCommand? {
        val text = raw.trim()
        if (!text.startsWith("/")) return null
        val body = text.drop(1).trimStart()
        if (body.isBlank()) return null
        val name = body.substringBefore(' ').lowercase()
        val command = byName[name] ?: return null
        val args = body.substringAfter(' ', missingDelimiterValue = "").trim()
        return ParsedSlashCommand(command, args)
    }

    fun matches(draft: String): List<SonarSlashCommand> {
        val typed = draft.trimStart().removePrefix("/").substringBefore(' ').lowercase()
        return hints.filter { command ->
            command.canonical.startsWith(typed) || command.aliases.any { it.startsWith(typed) }
        }
    }

    fun usage(command: SonarSlashCommand): String =
        when (command) {
            SonarSlashCommand.Message -> "usage: /msg @nickname [message]"
            SonarSlashCommand.Hug -> "usage: /hug <nickname>"
            SonarSlashCommand.Slap -> "usage: /slap <nickname>"
            SonarSlashCommand.Favorite -> "usage: /fav <nickname>"
            SonarSlashCommand.Unfavorite -> "usage: /unfav <nickname>"
            SonarSlashCommand.Block -> "usage: /block <nickname>"
            SonarSlashCommand.Unblock -> "usage: /unblock <nickname>"
            SonarSlashCommand.Who,
            SonarSlashCommand.Clear -> "/${command.canonical}"
        }
}
