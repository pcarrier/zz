package surf.zz.ui.history

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.Instant
import surf.zz.favicon.FaviconForUrl
import surf.zz.omnibox.SuggestionKind
import surf.zz.store.HistoryEntry
import surf.zz.ui.LocalHistoryStore
import surf.zz.url.UrlCanonicalizer
import surf.zz.util.SiteVisual

/**
 * A searchable browser of the global [surf.zz.store.HistoryStore], grouped by day.
 *
 * Direct port of iOS `HistoryView` (`HistoryView.swift`). Reached from the More
 * menu as a modal (the iOS sheet); on Android the host shows it full-screen and
 * the [onDismiss] callback closes it. Tapping a row opens its URL through the same
 * commit path the omnibox uses ([onOpen]) and dismisses.
 *
 * Mirrors the SwiftUI hierarchy:
 *  - `NavigationStack` + `.navigationTitle("History")` + toolbar → [Scaffold] with a
 *    [TopAppBar] titled "History", a "Done" confirmation action ([onDismiss]) and a
 *    destructive "Clear All" [IconButton] disabled when history is empty.
 *  - `.searchable(text:prompt:)` → an [OutlinedTextField] (state in [rememberSaveable]).
 *  - `ContentUnavailableView` → the [EmptyState] column ("No History"/"No Results").
 *  - `List { Section { ForEach … } }` → a [LazyColumn] with a `stickyHeader` per day
 *    group and `items(key = url)` rows.
 *  - `.onDelete` swipe → [SwipeToDismissBox]; `.contextMenu` Delete → long-press
 *    [DropdownMenu]; both call `history.delete(entry)`.
 *
 * @param onOpen opens the chosen URL in the focused pane (same path as omnibox select).
 * @param onDismiss closes the modal (the iOS `dismiss`).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun HistoryScreen(
    onOpen: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val history = LocalHistoryStore.current

    var query by rememberSaveable { mutableStateOf("") }

    // Live filter: reuse the omnibox ranker when there's a query (so results match
    // the URL bar), otherwise show all entries newest-first. Mirrors the Swift
    // `filteredEntries` computed property. `derivedStateOf` tracks the snapshot-backed
    // `history.entries` plus `query` and recomputes only when either changes.
    val filteredEntries by remember {
        derivedStateOf {
            val trimmed = query.trim()
            if (trimmed.isEmpty()) {
                history.entries
            } else {
                val items = history.omniboxSuggestions(query = trimmed, limit = 200)
                val matchedKeys = items
                    .filter { it.kind == SuggestionKind.HISTORY }
                    .map { UrlCanonicalizer.key(it.url) }
                    .toSet()
                history.entries.filter { matchedKeys.contains(it.canonicalKey) }
            }
        }
    }

    // Day grouping. `Instant.now()` is read once per recomposition of the groups,
    // matching the Swift `Self.grouped(filteredEntries, now: .now)`.
    val groups by remember {
        derivedStateOf { HistoryGrouping.grouped(filteredEntries, now = Instant.now()) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("History") },
                navigationIcon = {
                    // iOS `.confirmationAction` "Done".
                    TextButton(onClick = onDismiss) { Text("Done") }
                },
                actions = {
                    // iOS `.destructiveAction` "Clear All", disabled when empty.
                    IconButton(
                        onClick = { history.clear() },
                        enabled = history.entries.isNotEmpty(),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Delete,
                            contentDescription = "Clear All",
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            // `.searchable(text:$query, prompt:)`.
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                singleLine = true,
                leadingIcon = {
                    Icon(imageVector = Icons.Filled.Search, contentDescription = null)
                },
                placeholder = { Text("Search History") },
                keyboardOptions = KeyboardOptions.Default,
                keyboardActions = KeyboardActions.Default,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )

            if (groups.isEmpty()) {
                EmptyState(hasQuery = query.trim().isNotEmpty())
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = 12.dp),
                ) {
                    groups.forEach { group ->
                        // iOS `Section(group.title)` → a sticky day header.
                        stickyHeader(key = group.title) {
                            DayHeader(title = group.title)
                        }
                        items(group.entries, key = { it.url }) { entry ->
                            HistoryRow(
                                entry = entry,
                                onOpen = onOpen,
                                onDismiss = onDismiss,
                                onDelete = { history.delete(entry) },
                            )
                        }
                    }
                }
            }
        }
    }
}

/** Sticky day-section header (iOS `Section(title)`). */
@Composable
private fun DayHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

/**
 * A single history row.
 *
 * Port of the iOS `row(_:)`: a favicon + a medium-weight display title over a
 * monospaced secondary URL. Tapping opens the URL and dismisses; long-pressing
 * shows a destructive "Delete" menu (iOS `.contextMenu`); a left→right swipe
 * deletes (iOS `.onDelete`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryRow(
    entry: HistoryEntry,
    onOpen: (String) -> Unit,
    onDismiss: () -> Unit,
    onDelete: () -> Unit,
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value != SwipeToDismissBoxValue.Settled) {
                onDelete()
                true
            } else {
                false
            }
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        backgroundContent = { SwipeDeleteBackground() },
    ) {
        var menuExpanded by remember { mutableStateOf(false) }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surface)
                .combinedClickable(
                    onClick = {
                        onOpen(entry.url)
                        onDismiss()
                    },
                    onLongClick = { menuExpanded = true },
                ),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FaviconForUrl(
                    url = entry.url,
                    size = 18.dp,
                    fallback = Icons.Filled.History,
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = displayTitle(entry),
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = entry.url,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        // iOS `.truncationMode(.middle)`; Compose has no middle
                        // ellipsis, so the closest single-line truncation is used.
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { menuExpanded = false },
            ) {
                DropdownMenuItem(
                    text = { Text("Delete") },
                    leadingIcon = {
                        Icon(imageVector = Icons.Filled.Delete, contentDescription = null)
                    },
                    onClick = {
                        menuExpanded = false
                        onDelete()
                    },
                )
            }
        }
    }
}

/** Red swipe-to-delete background with a trailing trash glyph. */
@Composable
private fun SwipeDeleteBackground() {
    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Red.copy(alpha = 0.85f))
            .padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Spacer(Modifier.weight(1f))
        Icon(
            imageVector = Icons.Filled.Delete,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(20.dp),
        )
    }
}

/**
 * Empty state. Port of `ContentUnavailableView`: "No History" when there is no
 * query, "No Results" when a non-empty query matched nothing.
 */
@Composable
private fun EmptyState(hasQuery: Boolean) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.History,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(48.dp),
            )
            Text(
                text = if (hasQuery) "No Results" else "No History",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * Display title for [entry]: the trimmed title, or the host when the title is
 * blank. Port of the iOS `displayTitle(_:)`.
 */
private fun displayTitle(entry: HistoryEntry): String {
    val title = entry.title?.trim().orEmpty()
    return title.ifEmpty { SiteVisual.host(entry.url) }
}
