package surf.zz.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.item
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import surf.zz.prefs.NewWindowPolicy
import surf.zz.search.SearchEngine
import surf.zz.ui.LocalHistoryStore

/**
 * Settings form. Port of iOS `SettingsView` (`ios/zz/SettingsView.swift`).
 *
 * SwiftUI's grouped `Form` of `Section`s becomes a [LazyColumn] of grouped
 * [Card]s, each preceded by a `titleSmall` section header (the analog of the
 * `Section("…")` label). `Picker` → [ExposedDropdownMenuBox]; `TextField` →
 * [OutlinedTextField]; `Toggle` → a [Row] + [Switch]; the destructive
 * trash / "Clear History" buttons map to [IconButton] / [TextButton]. The toolbar
 * `Done` confirmation action becomes the [TopAppBar] action calling [onDismiss].
 *
 * State lives in [SettingsViewModel] (the `@AppStorage` / `@State` mirror), whose
 * [androidx.lifecycle.ViewModel] `StateFlow`s are observed with
 * [collectAsStateWithLifecycle]. The `HistoryStore` is read from the
 * [LocalHistoryStore] CompositionLocal, matching the iOS
 * `@Environment(HistoryStore.self)` injection; "Clear History" calls
 * `history.clear()` directly, exactly like the Swift button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onDismiss: () -> Unit,
    viewModel: SettingsViewModel = viewModel(),
) {
    val history = LocalHistoryStore.current

    val engine by viewModel.engine.collectAsStateWithLifecycle()
    val customTemplate by viewModel.customTemplate.collectAsStateWithLifecycle()
    val keywordEngines by viewModel.keywordEngines.collectAsStateWithLifecycle()
    val newWindowPolicy by viewModel.newWindowPolicy.collectAsStateWithLifecycle()
    val recordHistory by viewModel.recordHistory.collectAsStateWithLifecycle()
    val requestDesktopSite by viewModel.requestDesktopSite.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                actions = { TextButton(onClick = onDismiss) { Text("Done") } },
            )
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // --- Search ------------------------------------------------------
            item {
                SettingsSection("Search") {
                    EnumDropdown(
                        label = "Search Engine",
                        entries = SearchEngine.entries,
                        selected = engine,
                        displayName = { it.displayName },
                        onSelect = viewModel::onEngineChange,
                    )
                    // Shown only for the Custom engine (Swift `if selectedSearchEngine == .custom`).
                    if (engine == SearchEngine.CUSTOM) {
                        OutlinedTextField(
                            value = customTemplate,
                            onValueChange = viewModel::onCustomTemplateChange,
                            label = { Text("Search URL Template") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        CaptionText("Use %s where the search terms should go.")
                    }
                }
            }

            // --- Keyword Searches --------------------------------------------
            item {
                SettingsSection("Keyword Searches") {
                    keywordEngines.forEach { engineRow ->
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                OutlinedTextField(
                                    value = engineRow.keyword,
                                    onValueChange = { viewModel.updateKeyword(engineRow.id, it) },
                                    label = { Text("Keyword") },
                                    singleLine = true,
                                    modifier = Modifier.width(110.dp),
                                )
                                OutlinedTextField(
                                    value = engineRow.title,
                                    onValueChange = { viewModel.updateTitle(engineRow.id, it) },
                                    label = { Text("Title") },
                                    singleLine = true,
                                    modifier = Modifier.weight(1f),
                                )
                                IconButton(onClick = { viewModel.removeKeywordEngine(engineRow.id) }) {
                                    Icon(Icons.Filled.Delete, contentDescription = "Delete keyword search")
                                }
                            }
                            OutlinedTextField(
                                value = engineRow.templateURL,
                                onValueChange = { viewModel.updateTemplateURL(engineRow.id, it) },
                                label = { Text("Search URL Template") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    TextButton(onClick = viewModel::addKeywordEngine) {
                        Icon(Icons.Filled.Add, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Add Keyword Search")
                    }
                    CaptionText(
                        "Type the keyword followed by your query, e.g. \"gh swift\". " +
                            "Use %s where the search terms should go.",
                    )
                }
            }

            // --- Content -----------------------------------------------------
            item {
                SettingsSection("Content") {
                    ToggleRow(
                        label = "Request Desktop Site",
                        checked = requestDesktopSite,
                        onCheckedChange = viewModel::onRequestDesktopSiteChange,
                    )
                    CaptionText("Default for new tabs. Toggle per tile from its context menu.")
                }
            }

            // --- Pop-ups -----------------------------------------------------
            item {
                SettingsSection("Pop-ups") {
                    EnumDropdown(
                        label = "Open New Windows",
                        entries = NewWindowPolicy.entries,
                        selected = newWindowPolicy,
                        displayName = { it.displayName },
                        onSelect = viewModel::onNewWindowPolicyChange,
                    )
                }
            }

            // --- History -----------------------------------------------------
            item {
                SettingsSection("History") {
                    ToggleRow(
                        label = "Record Browsing History",
                        checked = recordHistory,
                        onCheckedChange = viewModel::onRecordHistoryChange,
                    )
                    TextButton(onClick = { history.clear() }) {
                        Text("Clear History")
                    }
                }
            }
        }
    }
}

/**
 * A grouped section: a `titleSmall` header followed by a [Card] holding the
 * section's rows. Mirrors a SwiftUI grouped-`Form` `Section("title") { … }`.
 */
@Composable
private fun SettingsSection(
    title: String,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(start = 4.dp),
        )
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                content()
            }
        }
    }
}

/** Secondary caption text (SwiftUI `.font(.caption).foregroundStyle(.secondary)`). */
@Composable
private fun CaptionText(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** A label + trailing [Switch] (SwiftUI `Toggle(label, isOn:)`). */
@Composable
private fun ToggleRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(text = label, style = MaterialTheme.typography.bodyLarge)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/**
 * A labeled dropdown over an enum's [entries] (SwiftUI `Picker(label, selection:)`
 * with a `ForEach(allCases)`), rendering each entry via [displayName] and
 * reporting selection through [onSelect].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> EnumDropdown(
    label: String,
    entries: List<T>,
    selected: T,
    displayName: (T) -> String,
    onSelect: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = Modifier.fillMaxWidth(),
    ) {
        OutlinedTextField(
            value = displayName(selected),
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            singleLine = true,
            modifier = Modifier
                .menuAnchor()
                .fillMaxWidth(),
        )
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            entries.forEach { entry ->
                DropdownMenuItem(
                    text = { Text(displayName(entry), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    onClick = {
                        onSelect(entry)
                        expanded = false
                    },
                )
            }
        }
    }
}
