package surf.zz.ui.history

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import surf.zz.store.HistoryEntry

/**
 * Pure day-bucketing + section-title formatting for the History screen.
 *
 * Direct 1:1 port of the static `HistoryView.grouped(_:now:)` / `title(for:now:calendar:)`
 * helpers and the `DayGroup` struct from iOS `HistoryView.swift`.
 *
 * Pure and side-effect free (unit-testable). The Swift code uses `Calendar.current`
 * (the device's current time zone); the Kotlin port uses [ZoneId.systemDefault] to
 * convert each entry's [Instant] to a [LocalDate] in the local zone, matching
 * `calendar.startOfDay(for:)`. Likewise titles use the default [Locale] for the
 * localized long style, mirroring `DateFormatter` defaults.
 */
object HistoryGrouping {

    /**
     * A day bucket of history entries.
     *
     * Port of `HistoryView.DayGroup`. Sections are keyed by [title] (the Swift
     * `ForEach(groups, id: \.title)`), so [title] is the stable identity.
     */
    data class DayGroup(
        val title: String,
        val entries: List<HistoryEntry>,
    )

    /**
     * Groups [entries] (arbitrary order) into day buckets ordered newest-day-first,
     * each bucket sorted newest-visit-first.
     *
     * Mirrors the Swift `grouped(_:now:)`: sort all entries descending by
     * `lastVisited`, then bucket by start-of-day in insertion order (a
     * [LinkedHashMap] preserves the newest-first day order, equivalent to the Swift
     * `order: [Date]` accumulator).
     */
    fun grouped(entries: List<HistoryEntry>, now: Instant): List<DayGroup> {
        val zone = ZoneId.systemDefault()
        val today = now.atZone(zone).toLocalDate()
        val sorted = entries.sortedByDescending { it.lastVisited }
        val byDay = LinkedHashMap<LocalDate, MutableList<HistoryEntry>>()
        for (entry in sorted) {
            val day = entry.lastVisited.atZone(zone).toLocalDate()
            byDay.getOrPut(day) { mutableListOf() }.add(entry)
        }
        return byDay.map { (day, dayEntries) ->
            DayGroup(title = title(day, today), entries = dayEntries)
        }
    }

    /**
     * Section title for [day] relative to [now] (both [LocalDate]s in the same zone).
     *
     * Port of `title(for:now:calendar:)`:
     *  - "Today" / "Yesterday" for the two most recent days;
     *  - `"EEEE, MMMM d"` (e.g. "Monday, June 1") when [day] is in the same year as
     *    [now];
     *  - otherwise the localized long date style (Swift `DateFormatter.dateStyle = .long`).
     */
    fun title(day: LocalDate, now: LocalDate): String {
        if (day == now) return "Today"
        if (day == now.minusDays(1)) return "Yesterday"
        val formatter = if (day.year == now.year) {
            sameYearFormatter()
        } else {
            DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(Locale.getDefault())
        }
        return day.format(formatter)
    }

    /** Matches the Swift `"EEEE, MMMM d"` pattern; uses the default locale for names. */
    private fun sameYearFormatter(): DateTimeFormatter =
        DateTimeFormatter.ofPattern("EEEE, MMMM d", Locale.getDefault())
}
