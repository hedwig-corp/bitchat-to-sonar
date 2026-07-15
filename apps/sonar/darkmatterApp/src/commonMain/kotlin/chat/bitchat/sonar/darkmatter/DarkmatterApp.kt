package chat.bitchat.sonar.darkmatter

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.StateFlow

private val DarkmatterColors: ColorScheme = darkColorScheme(
    primary = Color(0xFFB799FF),
    onPrimary = Color(0xFF1D1237),
    secondary = Color(0xFF5CE1E6),
    background = Color(0xFF090712),
    onBackground = Color(0xFFF5F0FF),
    surface = Color(0xFF151022),
    onSurface = Color(0xFFF5F0FF),
    surfaceVariant = Color(0xFF241A38),
    onSurfaceVariant = Color(0xFFCFC3E6),
    error = Color(0xFFFF8A9B),
)

@Composable
fun SonarDarkmatterApp(
    stateFlow: StateFlow<DarkmatterUiState>,
    controller: DarkmatterController,
) {
    val state by stateFlow.collectAsState()
    var showNewConversation by remember { mutableStateOf(false) }

    MaterialTheme(colorScheme = DarkmatterColors) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .windowInsetsPadding(WindowInsets.safeDrawing),
            ) {
                when {
                    !state.localReady -> LoadingScreen("Opening encrypted storage…")
                    state.account == null -> OnboardingScreen(state, controller)
                    state.selectedConversationId == null -> ConversationListScreen(
                        state = state,
                        onSelect = controller::selectConversation,
                        onNewConversation = { showNewConversation = true },
                        onRetryPending = controller::retryPending,
                    )
                    else -> ConversationScreen(state, controller)
                }
            }
        }

        if (showNewConversation) {
            NewConversationDialog(
                onDismiss = { showNewConversation = false },
                onCreate = { member, title ->
                    showNewConversation = false
                    controller.beginConversation(member, title)
                },
            )
        }

        state.error?.let { error ->
            AlertDialog(
                onDismissRequest = controller::dismissError,
                title = { Text("Darkmatter needs attention") },
                text = { Text(error) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            controller.dismissError()
                            if (!state.connected) controller.retryConnection()
                        },
                    ) {
                        Text(if (state.connected) "OK" else "Retry")
                    }
                },
            )
        }
    }
}

@Composable
private fun LoadingScreen(label: String) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator(color = MaterialTheme.colorScheme.secondary)
        Spacer(Modifier.height(20.dp))
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun OnboardingScreen(state: DarkmatterUiState, controller: DarkmatterController) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        DarkmatterMark()
        Spacer(Modifier.height(28.dp))
        Text(
            "Sonar Darkmatter",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(10.dp))
        Text(
            "An isolated Marmot experiment powered by MDK v0.9.4.",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.secondary,
        )
        Spacer(Modifier.height(22.dp))
        Text(
            "This app creates a fresh identity and encrypted database. It cannot read your Sonar account, wallet, messages, push token, or app files.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            lineHeight = 22.sp,
        )
        Spacer(Modifier.height(30.dp))
        Button(
            onClick = controller::createIdentity,
            enabled = !state.creatingIdentity,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (state.creatingIdentity) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onPrimary,
                )
                Spacer(Modifier.size(10.dp))
            }
            Text(if (state.creatingIdentity) "Creating identity…" else "Create isolated identity")
        }
        if (state.connecting) {
            Spacer(Modifier.height(12.dp))
            Text(
                "Connecting to Marmot relays…",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ConversationListScreen(
    state: DarkmatterUiState,
    onSelect: (String) -> Unit,
    onNewConversation: () -> Unit,
    onRetryPending: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            DarkmatterMark(size = 42)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(start = 12.dp),
            ) {
                Text("Sonar Darkmatter", fontWeight = FontWeight.Bold, fontSize = 21.sp)
                Text(
                    state.account?.npub?.compactIdentity().orEmpty(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
            }
            ConnectionPill(state.connected, state.connecting)
        }

        if (state.conversations.isEmpty()) {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text("No Darkmatter chats yet", style = MaterialTheme.typography.headlineSmall)
                Spacer(Modifier.height(10.dp))
                Text(
                    "Start with an npub. The chat appears locally before relay setup finishes.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(state.conversations, key = { it.id }) { conversation ->
                    ConversationRow(conversation, onSelect, onRetryPending)
                }
            }
        }

        Button(
            onClick = onNewConversation,
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
        ) {
            Text("New Darkmatter chat")
        }
    }
}

@Composable
private fun ConversationRow(
    conversation: DarkmatterConversation,
    onSelect: (String) -> Unit,
    onRetryPending: (String) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onSelect(conversation.id) }
            .padding(horizontal = 20.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(46.dp)
                .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(conversation.title.firstOrNull()?.uppercase() ?: "D", fontWeight = FontWeight.Bold)
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(start = 14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    conversation.title,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    fontWeight = FontWeight.SemiBold,
                )
                if (conversation.unreadCount > 0) {
                    Text(
                        conversation.unreadCount.toString(),
                        color = MaterialTheme.colorScheme.secondary,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
            Text(
                conversation.setupError ?: conversation.preview.ifBlank { "Encrypted chat" },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = if (conversation.setupError == null) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.error
                },
                fontSize = 13.sp,
            )
        }
        if (conversation.setupError != null) {
            TextButton(onClick = { onRetryPending(conversation.id) }) { Text("Retry") }
        } else if (conversation.isPendingSetup) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun ConversationScreen(state: DarkmatterUiState, controller: DarkmatterController) {
    val selectedId = state.selectedConversationId ?: return
    val conversation = state.conversations.firstOrNull { it.id == selectedId }
    val title = conversation?.title ?: "Darkmatter chat"
    val listState = rememberLazyListState()
    var composer by remember(selectedId) { mutableStateOf("") }

    LaunchedEffect(selectedId, state.messages.size) {
        if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.lastIndex)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .imePadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = controller::closeConversation) { Text("Back") }
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.Bold, maxLines = 1)
                Text(
                    if (conversation?.isPendingSetup == true) "Setting up locally…" else "MDK v0.9.4",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
            }
            ConnectionPill(state.connected, state.connecting)
        }

        if (conversation?.pendingConfirmation == true) {
            InviteBanner(
                onAccept = { controller.acceptInvite(selectedId) },
                onDecline = { controller.declineInvite(selectedId) },
            )
        }
        conversation?.setupError?.let {
            ErrorBanner(it) { controller.retryPending(selectedId) }
        }

        LazyColumn(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            state = listState,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (state.hasMoreBefore) {
                item(key = "load-older") {
                    TextButton(
                        onClick = controller::loadOlder,
                        enabled = !state.loadingOlder,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(if (state.loadingOlder) "Loading…" else "Load older messages")
                    }
                }
            }
            items(state.messages, key = { it.id }) { message ->
                MessageBubble(message)
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            OutlinedTextField(
                value = composer,
                onValueChange = { composer = it.take(DarkmatterController.MAX_MESSAGE_LENGTH) },
                modifier = Modifier.weight(1f),
                placeholder = { Text("Message") },
                maxLines = 5,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(
                    onSend = {
                        controller.sendMessage(composer)
                        composer = ""
                    },
                ),
            )
            Spacer(Modifier.size(8.dp))
            Button(
                onClick = {
                    controller.sendMessage(composer)
                    composer = ""
                },
                enabled = composer.isNotBlank(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
                modifier = Modifier.height(56.dp),
            ) {
                Text("Send")
            }
        }
    }
}

@Composable
private fun MessageBubble(message: DarkmatterMessage) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (message.isOwn) Arrangement.End else Arrangement.Start,
    ) {
        Card(
            colors = CardDefaults.cardColors(
                containerColor = if (message.isOwn) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.surfaceVariant
                },
            ),
            shape = RoundedCornerShape(18.dp),
            modifier = Modifier.fillMaxWidth(0.82f),
        ) {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                if (!message.isOwn) {
                    Text(
                        message.sender.compactIdentity(),
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.secondary,
                    )
                    Spacer(Modifier.height(3.dp))
                }
                Text(
                    message.text,
                    color = if (message.isOwn) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                )
                if (message.isOwn && message.delivery != DarkmatterDelivery.DELIVERED) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        when (message.delivery) {
                            DarkmatterDelivery.QUEUED -> "Queued locally"
                            DarkmatterDelivery.SENDING -> "Sending…"
                            DarkmatterDelivery.FAILED -> message.invalidationReason ?: "Not delivered"
                            DarkmatterDelivery.DELIVERED -> ""
                        },
                        color = if (message.delivery == DarkmatterDelivery.FAILED) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.72f)
                        },
                        fontSize = 11.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun InviteBanner(onAccept: () -> Unit, onDecline: () -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 6.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text("Group invitation", fontWeight = FontWeight.Bold)
            Text("Accept before sending messages.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = onDecline) { Text("Decline") }
                Button(onClick = onAccept) { Text("Accept") }
            }
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onRetry: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.error.copy(alpha = 0.12f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(message, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.error)
        TextButton(onClick = onRetry) { Text("Retry") }
    }
}

@Composable
private fun NewConversationDialog(onDismiss: () -> Unit, onCreate: (String, String) -> Unit) {
    var member by remember { mutableStateOf("") }
    var title by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("New Darkmatter chat") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "A local conversation opens immediately; relay and KeyPackage work continues in the background.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(
                    value = member,
                    onValueChange = { member = it.take(DarkmatterController.MAX_MEMBER_REFERENCE_LENGTH) },
                    label = { Text("Member npub or hex key") },
                    singleLine = true,
                )
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it.take(DarkmatterController.MAX_TITLE_LENGTH) },
                    label = { Text("Chat name (optional)") },
                    singleLine = true,
                )
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        confirmButton = {
            Button(onClick = { onCreate(member, title) }, enabled = member.isNotBlank()) {
                Text("Create")
            }
        },
    )
}

@Composable
private fun ConnectionPill(connected: Boolean, connecting: Boolean) {
    val label = when {
        connected -> "Online"
        connecting -> "Connecting"
        else -> "Local"
    }
    val color = when {
        connected -> MaterialTheme.colorScheme.secondary
        connecting -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row(
        modifier = Modifier
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).background(color, CircleShape))
        Spacer(Modifier.size(6.dp))
        Text(label, color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun DarkmatterMark(size: Int = 70) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size((size * 0.58f).dp)
                .background(MaterialTheme.colorScheme.primary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size((size * 0.22f).dp)
                    .background(MaterialTheme.colorScheme.secondary, CircleShape),
            )
        }
    }
}

private fun String.compactIdentity(): String = when {
    length <= 24 -> this
    else -> take(12) + "…" + takeLast(8)
}
