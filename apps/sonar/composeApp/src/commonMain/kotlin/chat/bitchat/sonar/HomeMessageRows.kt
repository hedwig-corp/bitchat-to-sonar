package chat.bitchat.sonar

/**
 * One Home / sidebar Messages row after mesh and Marmot sources are unified.
 * Sealed so LazyColumn keys never need a force-unwrap on a dual-nullable pair.
 */
internal sealed class HomeMessageRow {
    data class Mesh(val row: MeshDmRow) : HomeMessageRow()
    data class Marmot(val chat: SonarChat) : HomeMessageRow()

    val listKey: String
        get() = when (this) {
            is Mesh -> "mesh:" + row.peerId
            is Marmot -> chat.id
        }
}

/**
 * Merge BLE-mesh / folded rows with standalone Marmot chats into ONE
 * recency-ordered list (Signal-style / iOS `SonarAppStore.dmRows` parity).
 *
 * [marmotTsSecs] must be O(1) per id (cached row VM). Pending chats should
 * return their creation time, not 0, so a freshly-started secure chat does
 * not sink under history.
 */
internal fun mergeHomeMessageRows(
    meshRows: List<MeshDmRow>,
    chatRows: List<SonarChat>,
    marmotTsSecs: (chatId: String) -> Long,
): List<HomeMessageRow> =
    buildList(meshRows.size + chatRows.size) {
        meshRows.forEach { add(HomeMessageRow.Mesh(it)) }
        chatRows.forEach { add(HomeMessageRow.Marmot(it)) }
    }.sortedByDescending { row ->
        when (row) {
            is HomeMessageRow.Mesh -> row.row.tsSecs
            is HomeMessageRow.Marmot -> marmotTsSecs(row.chat.id)
        }
    }
