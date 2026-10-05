package surf.zz.ui.omnibox

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tab
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import surf.zz.favicon.Favicon
import surf.zz.omnibox.OmniboxItem
import surf.zz.omnibox.SuggestionKind
import surf.zz.ui.theme.accent
import surf.zz.ui.theme.secondaryLabelText
import surf.zz.util.SiteVisual

/**
 * Dropdown autocomplete panel shown beneath the omnibox. Ports
 * `SuggestionList` / `SuggestionRow` from `URLBar.swift`.
 *
 * Deviations from iOS (documented):
 *  - The SwiftUI `PreferenceKey` frame-measurement that derived `maxVisibleHeight`
 *    from the last visible row's `maxY` is dropped. Compose has no equivalent need:
 *    rows have an intrinsic, fixed height, so we cap the panel at
 *    [maxVisibleRows] * [rowHeight] via `heightIn(max = ...)`. The `LazyColumn`
 *    scrolls the overflow.
 *  - The `DragGesture(minimumDistance: 0)` + `isTapSized` double-fire guard and the
 *    `didSelect` one-shot latch are dropped: a Compose `Modifier.clickable` fires a
 *    single onClick per tap, so a plain click handler suffices.
 *  - `preservesKeyboardOnScroll()` (iOS `scrollDismissesKeyboard(.never)`) is a no-op
 *    default on Android — scrolling a `LazyColumn` does not dismiss the IME by itself.
 */

/** Max number of rows shown before the panel scrolls. Swift: `maxVisibleRows = 5`. */
private const val maxVisibleRows = 5

/** Intrinsic height of a single suggestion row (icon + two text lines + padding). */
private val rowHeight: Dp = 48.dp

@Composable
fun SuggestionList(
    suggestions: List<OmniboxItem>,
    modifier: Modifier = Modifier,
    selectedIndex: Int? = null,
    onSelect: (OmniboxItem) -> Unit,
) {
    val listState = rememberLazyListState()

    // Scroll the selected row into view when the selection moves or the suggestion
    // set changes (Swift: onChange(selectedSuggestionID) / onChange(suggestions ids)).
    val ids = remember(suggestions) { suggestions.map { it.id } }
    LaunchedEffect(selectedIndex, ids) {
        val index = selectedIndex ?: return@LaunchedEffect
        if (index in suggestions.indices) {
            listState.animateScrollToItem(index)
        }
    }

    val visibleCount = suggestions.size.coerceAtMost(maxVisibleRows)
    val maxHeight = rowHeight * visibleCount

    Surface(
        modifier = modifier
            .shadow(elevation = 18.dp)
            .border(
                width = 1.dp,
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
            ),
        color = MaterialTheme.colorScheme.surfaceContainer,
        tonalElevation = 3.dp,
    ) {
        LazyColumn(
            state = listState,
            modifier = Modifier.heightIn(max = maxHeight),
        ) {
            itemsIndexed(
                items = suggestions,
                key = { _, item -> item.id },
            ) { idx, item ->
                SuggestionRow(
                    item = item,
                    isSelected = idx == selectedIndex,
                    onSelect = onSelect,
                )
                if (idx < suggestions.size - 1) {
                    HorizontalDivider(
                        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                    )
                }
            }
        }
    }
}

@Composable
private fun SuggestionRow(
    item: OmniboxItem,
    isSelected: Boolean,
    onSelect: (OmniboxItem) -> Unit,
) {
    val rowBackground = if (isSelected) {
        MaterialTheme.colorScheme.accent.copy(alpha = 0.18f)
    } else {
        Color.Transparent
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = { onSelect(item) },
            )
            .background(rowBackground)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Leading icon: favicon for history/open-tab, Material icon for search/open.
        Box(
            modifier = Modifier.width(16.dp),
            contentAlignment = Alignment.Center,
        ) {
            LeadingIcon(item)
        }

        // Title + monospaced URL stack.
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                text = highlighted(
                    displayTitle(item),
                    ranges = titleRanges(item),
                    base = MaterialTheme.colorScheme.onSurface,
                    accent = MaterialTheme.colorScheme.accent,
                ),
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = highlighted(
                    item.url,
                    ranges = item.urlRanges,
                    base = MaterialTheme.colorScheme.secondaryLabelText,
                    accent = MaterialTheme.colorScheme.accent,
                ),
                fontFamily = FontFamily.Monospace,
                fontSize = 15.sp,
                maxLines = 1,
                // iOS truncates the URL in the middle; Compose lacks a built-in
                // middle ellipsis, so we use end truncation (closest faithful match).
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Switch-to-Tab pill for open-tab rows. The title/URL Column above carries
        // the weight, so the pill is pushed to the trailing edge (iOS: Spacer + pill).
        if (item.kind == SuggestionKind.OPEN_TAB) {
            Text(
                text = "Switch to Tab",
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .background(
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.12f),
                        shape = RoundedCornerShape(50),
                    )
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}

@Composable
private fun LeadingIcon(item: OmniboxItem) {
    when (item.kind) {
        SuggestionKind.HISTORY, SuggestionKind.OPEN_TAB -> {
            // Favicon with a kind-specific fallback symbol (Swift: clock vs. tabs).
            Favicon(
                host = SiteVisual.host(item.url),
                size = 16.dp,
                fallback = if (item.kind == SuggestionKind.OPEN_TAB) {
                    Icons.Filled.Tab
                } else {
                    Icons.Filled.History
                },
            )
        }
        SuggestionKind.SEARCH, SuggestionKind.OPEN -> {
            Icon(
                imageVector = if (item.kind == SuggestionKind.SEARCH) {
                    Icons.Filled.Search
                } else {
                    Icons.AutoMirrored.Filled.OpenInNew
                },
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier.size(12.dp),
            )
        }
    }
}

/**
 * Display title: the EXACT raw string the title ranges were computed against
 * (`title ?? ""` from `OmniboxRanker`), falling back to the host only when empty.
 * Swift: `SuggestionRow.displayTitle`.
 */
private fun displayTitle(item: OmniboxItem): String {
    val title = item.title ?: ""
    return if (title.isEmpty()) SiteVisual.host(item.url) else title
}

/**
 * Title ranges are valid only while the displayed title is the raw title; once we
 * fall back to the host they no longer line up, so drop them.
 * Swift: `SuggestionRow.titleRanges`.
 */
private fun titleRanges(item: OmniboxItem): List<IntRange> =
    if (!item.title.isNullOrEmpty()) item.titleRanges else emptyList()

/**
 * Builds an [AnnotatedString] coloring the whole string with [base] and applying
 * a bold [accent] [SpanStyle] over each matched [IntRange]. Ranges are UTF-16 char
 * offsets emitted by `OmniboxRanker`, lined up to `AnnotatedString` offsets.
 *
 * Swift: `SuggestionRow.attributed(_:ranges:base:)`. Ranges are clamped against the
 * live string to guard against drift.
 */
private fun highlighted(
    string: String,
    ranges: List<IntRange>,
    base: Color,
    accent: Color,
): AnnotatedString = buildAnnotatedString {
    withStyle(SpanStyle(color = base)) {
        append(string)
    }
    val accentStyle = SpanStyle(color = accent, fontWeight = FontWeight.Bold)
    for (r in ranges) {
        val lo = r.first
        // IntRange is inclusive; AnnotatedString.addStyle end is exclusive. The
        // ranges emitted by OmniboxRanker are half-open expressed as `lo until hi`
        // (i.e. `lo..hi-1`), so the exclusive end is `r.last + 1`.
        val hi = r.last + 1
        if (lo in 0..string.length && hi in 0..string.length && lo < hi) {
            addStyle(accentStyle, lo, hi)
        }
    }
}
