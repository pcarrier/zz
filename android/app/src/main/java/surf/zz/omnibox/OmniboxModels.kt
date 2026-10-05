package surf.zz.omnibox

import java.util.UUID

/**
 * Omnibox value types ported 1:1 from `BrowserStore.swift` (lines 1369–1408).
 *
 * These are pure, UI-agnostic data types: the kind of a suggestion row, the
 * selection-routing decision shared by click-select and keyboard-submit, and the
 * suggestion item itself. Highlight ranges are `IntRange` char offsets (UTF-16),
 * emitted by `OmniboxRanker` so a Compose `AnnotatedString.addStyle(start, end)`
 * lines up directly (see ANDROID_ARCH.md §5 "String highlight ranges").
 */

/** Swift: `enum SuggestionKind { case search, open, openTab, history }`. */
enum class SuggestionKind { SEARCH, OPEN, OPEN_TAB, HISTORY }

/**
 * Selection routing decision, shared by click-select and keyboard-submit so an
 * open-tab row never reloads. Pure + testable.
 *
 * Swift: `enum OmniboxRoute: Equatable { case focus(UUID); case load(String) }`.
 */
sealed interface OmniboxRoute {
    data class Focus(val tabId: UUID) : OmniboxRoute
    data class Load(val url: String) : OmniboxRoute

    companion object {
        fun route(item: OmniboxItem): OmniboxRoute {
            val id = item.tabId
            if (item.kind == SuggestionKind.OPEN_TAB && id != null) {
                return Focus(id)
            }
            return Load(item.url)
        }
    }
}

/**
 * A single omnibox suggestion row.
 *
 * Swift: `struct OmniboxItem: Identifiable, Hashable`. `titleRanges`/`urlRanges`
 * are character-offset ranges used to highlight the matched substrings.
 */
data class OmniboxItem(
    val id: String,
    val url: String,
    val title: String?,
    val kind: SuggestionKind,
    val tabId: UUID? = null,
    val titleRanges: List<IntRange> = emptyList(),
    val urlRanges: List<IntRange> = emptyList(),
)
