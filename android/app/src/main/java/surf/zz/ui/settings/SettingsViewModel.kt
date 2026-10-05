package surf.zz.ui.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import java.util.UUID
import surf.zz.prefs.AppPreferences
import surf.zz.prefs.BrowserPreferences
import surf.zz.prefs.NewWindowPolicy
import surf.zz.search.KeywordEngine
import surf.zz.search.SearchEngine
import surf.zz.search.SearchPreferences

/**
 * State holder for [SettingsScreen].
 *
 * Port of `ios/zz/SettingsView.swift`. On iOS the view bound its controls
 * directly to `@AppStorage(...)` (a `UserDefaults`-backed two-way `@State`) plus a
 * single `@State private var keywordEngines` array persisted via `.onChange`.
 * SwiftUI's `@AppStorage` gives "read once, write on change, recompose on the new
 * value" for free; this ViewModel reconstructs that contract on Android, where
 * Compose has no equivalent two-way binding into a preference store.
 *
 * ## Why a ViewModel (and the only one in the app)
 *
 * Per ANDROID_ARCH.md §3 the browser core is deliberately *not* MVVM — its stores
 * are plain `@Observable`-style snapshot-state classes. Settings is the sole
 * exception: a self-contained screen whose only job is reading/writing scalar
 * preferences, so a small [ViewModel] that survives recomposition and owns the
 * debounce coroutine is the natural fit.
 *
 * ## Source of truth
 *
 * Reads and writes go through the synchronous [SearchPreferences] /
 * [BrowserPreferences] façades (the `SharedPreferences`-backed scalar layer in
 * `surf.zz.prefs`). Those façades stay the single source of truth because the
 * omnibox hot path (`SearchPreferences.activeTemplate`, `KeywordBangs`) reads them
 * synchronously on every keystroke and must observe a setting change immediately —
 * a second, racing DataStore over the same keys, or a `suspend` read, would let
 * the omnibox lag the Settings UI. The [StateFlow]s here are a *view* of that
 * store: seeded from it at construction (the `@AppStorage` initial read) and
 * updated in lock-step with each write, exactly as `@AppStorage` mirrors
 * `UserDefaults`.
 *
 * ## keywordEngines debounce (port of SwiftUI `.onChange`)
 *
 * The Swift view rewrote the whole `[KeywordEngine]` array to `UserDefaults` on
 * every edit via `.onChange(of: keywordEngines)`. Here [keywordEngines] is an
 * editable [MutableStateFlow]; a [debounce] collector ([persistKeywordEngines])
 * coalesces the burst of edits produced while typing into a keyword/title/URL
 * field and persists the JSON array, matching the debounced-write convention in
 * ANDROID_ARCH.md §6. The initial emission is [drop]ped so merely opening Settings
 * never rewrites an unchanged store.
 *
 * History clearing (`history.clear()` in the Swift `Section("History")`) is left
 * to the screen, which holds the app-global `HistoryStore` via `LocalHistoryStore`;
 * this ViewModel deliberately wraps only the preference façades it owns.
 *
 * All mutation happens on the main thread (the ViewModel is used from
 * composition); the debounce collector runs on [viewModelScope]'s main dispatcher
 * and the underlying `apply()` writes flush to disk asynchronously.
 */
@OptIn(FlowPreview::class)
class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    /**
     * The scalar-preference façade used for the two keys that [SearchPreferences]
     * exposes only as read-only accessors (`selectedEngine`, `customTemplate`).
     * Writes go through [AppPreferences] using the same public key constants
     * (`ENGINE_KEY` / `CUSTOM_TEMPLATE_KEY`) the façade reads from, so the omnibox
     * sees the change on its next synchronous read — the Android analog of an
     * `@AppStorage` write hitting the very `UserDefaults` key the rest of the app
     * reads. (`SharedPreferences` is a process-wide singleton, so this instance
     * observes the same store as the engine façades; no second store is created.)
     */
    private val appPreferences = AppPreferences(application)

    // --- Search engine ---------------------------------------------------------
    //
    // @AppStorage(SearchPreferences.engineKey) searchEngineRaw, surfaced as the
    // resolved SearchEngine. Swift kept the raw string and resolved it lazily via
    // `selectedSearchEngine`; resolving up front is equivalent and lets the picker
    // bind to the enum directly (an unknown stored raw falls back to the default
    // inside SearchPreferences.selectedEngine, matching `?? defaultEngine`).

    private val _engine = MutableStateFlow(SearchPreferences.selectedEngine)
    val engine: StateFlow<SearchEngine> = _engine.asStateFlow()

    /** "Search Engine" picker selection changed. */
    fun onEngineChange(value: SearchEngine) {
        if (_engine.value == value) return
        appPreferences.putString(SearchPreferences.ENGINE_KEY, value.rawValue)
        _engine.value = value
    }

    // --- Custom search template ------------------------------------------------
    //
    // @AppStorage(SearchPreferences.customTemplateKey) customSearchTemplate. The
    // screen only shows the field when engine == CUSTOM, but the value is owned
    // unconditionally to match the always-bound @AppStorage.

    private val _customTemplate = MutableStateFlow(SearchPreferences.customTemplate)
    val customTemplate: StateFlow<String> = _customTemplate.asStateFlow()

    /** "Search URL Template" text field edited. */
    fun onCustomTemplateChange(value: String) {
        if (_customTemplate.value == value) return
        appPreferences.putString(SearchPreferences.CUSTOM_TEMPLATE_KEY, value)
        _customTemplate.value = value
    }

    // --- New-window policy -----------------------------------------------------
    //
    // @AppStorage(BrowserPreferences.newWindowPolicyKey) newWindowPolicyRaw.

    private val _newWindowPolicy = MutableStateFlow(BrowserPreferences.newWindowPolicy)
    val newWindowPolicy: StateFlow<NewWindowPolicy> = _newWindowPolicy.asStateFlow()

    /** "Open New Windows" picker selection changed. */
    fun onNewWindowPolicyChange(value: NewWindowPolicy) {
        if (_newWindowPolicy.value == value) return
        BrowserPreferences.newWindowPolicy = value
        _newWindowPolicy.value = value
    }

    // --- Record history --------------------------------------------------------
    //
    // @AppStorage(BrowserPreferences.recordHistoryKey) recordHistory = true.

    private val _recordHistory = MutableStateFlow(BrowserPreferences.recordsHistory)
    val recordHistory: StateFlow<Boolean> = _recordHistory.asStateFlow()

    /** "Record Browsing History" toggle changed. */
    fun onRecordHistoryChange(value: Boolean) {
        if (_recordHistory.value == value) return
        BrowserPreferences.recordsHistory = value
        _recordHistory.value = value
    }

    // --- Request desktop site --------------------------------------------------
    //
    // @AppStorage(BrowserPreferences.requestDesktopSiteKey) requestsDesktopSite —
    // the default content mode applied to newly created tabs.

    private val _requestDesktopSite = MutableStateFlow(BrowserPreferences.requestsDesktopSite)
    val requestDesktopSite: StateFlow<Boolean> = _requestDesktopSite.asStateFlow()

    /** "Request Desktop Site" toggle changed. */
    fun onRequestDesktopSiteChange(value: Boolean) {
        if (_requestDesktopSite.value == value) return
        BrowserPreferences.requestsDesktopSite = value
        _requestDesktopSite.value = value
    }

    // --- Keyword ("bang") engines ----------------------------------------------
    //
    // @State private var keywordEngines + .onChange persisting the whole array to
    // UserDefaults. Editable list; persisted as JSON by the debounced collector.

    private val _keywordEngines = MutableStateFlow(SearchPreferences.keywordEngines)
    val keywordEngines: StateFlow<List<KeywordEngine>> = _keywordEngines.asStateFlow()

    init {
        persistKeywordEngines()
    }

    /**
     * Debounced JSON persistence of [keywordEngines], the Android analog of the
     * Swift `.onChange(of: keywordEngines) { SearchPreferences.keywordEngines = $0 }`.
     *
     * [drop] skips the initial seeded emission so opening Settings never rewrites
     * the store; [debounce] coalesces the rapid edits produced while the user
     * types into a keyword/title/template field. The collector lives for the
     * ViewModel's lifetime on [viewModelScope].
     */
    private fun persistKeywordEngines() {
        viewModelScope.launch {
            _keywordEngines
                .drop(1)
                .debounce(KEYWORD_ENGINES_DEBOUNCE_MS)
                .collect { engines -> SearchPreferences.keywordEngines = engines }
        }
    }

    /**
     * "Add Keyword Search" button. Appends a blank row seeded with the example
     * template, matching the Swift `keywordEngines.append(...)`.
     */
    fun addKeywordEngine() {
        _keywordEngines.value = _keywordEngines.value + KeywordEngine(
            keyword = "",
            templateURL = "https://example.com/search?q=%s",
            title = "",
        )
    }

    /** Per-row trash button: `keywordEngines.removeAll { $0.id == engine.id }`. */
    fun removeKeywordEngine(id: UUID) {
        _keywordEngines.value = _keywordEngines.value.filterNot { it.id == id }
    }

    /** "Keyword" field edited for the row identified by [id] (`$engine.keyword`). */
    fun updateKeyword(id: UUID, keyword: String) {
        updateKeywordEngine(id) { it.copy(keyword = keyword) }
    }

    /** "Title" field edited for the row identified by [id] (`$engine.title`). */
    fun updateTitle(id: UUID, title: String) {
        updateKeywordEngine(id) { it.copy(title = title) }
    }

    /** "Search URL Template" field edited for the row (`$engine.templateURL`). */
    fun updateTemplateURL(id: UUID, templateURL: String) {
        updateKeywordEngine(id) { it.copy(templateURL = templateURL) }
    }

    private inline fun updateKeywordEngine(id: UUID, transform: (KeywordEngine) -> KeywordEngine) {
        _keywordEngines.value = _keywordEngines.value.map { if (it.id == id) transform(it) else it }
    }

    private companion object {
        /**
         * Debounce window for keyword-engine writes. Sits in the 250–500ms band
         * ANDROID_ARCH.md §6 uses for debounced persistence; keyword edits are
         * low-frequency, so 300ms keeps the store fresh without a write per
         * keystroke.
         */
        const val KEYWORD_ENGINES_DEBOUNCE_MS = 300L
    }
}
