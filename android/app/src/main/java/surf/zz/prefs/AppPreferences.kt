package surf.zz.prefs

import android.content.Context
import android.content.SharedPreferences

/**
 * Synchronous, scalar preference layer underpinning `SearchPreferences` and
 * `BrowserPreferences`.
 *
 * ## Why this exists (no single Swift source)
 *
 * On iOS the search/browser preference enums read directly from
 * `UserDefaults.standard` (see `ios/zz/SearchEngine.swift`):
 *
 * ```swift
 * UserDefaults.standard.string(forKey: engineKey)
 * UserDefaults.standard.data(forKey: keywordEnginesKey)
 * UserDefaults.standard.object(forKey: recordHistoryKey) != nil   // 3-state default
 * UserDefaults.standard.bool(forKey: recordHistoryKey)
 * ```
 *
 * `UserDefaults` is a synchronous key/value store. The closest Android analog
 * with the same synchronous read semantics is [SharedPreferences] — and that
 * matters here: these keys are read on the omnibox hot path (every keystroke
 * routes through `SearchPreferences.activeTemplate` / `KeywordBangs`), so a
 * `suspend` DataStore read would be wrong. DataStore is reserved for the
 * Settings screen's reactive flows (`SettingsViewModel`); the synchronous
 * scalar reads go through here.
 *
 * [SharedPreferences] keeps its values in an in-memory map after the first
 * load, so reads after warm-up never touch disk — an "in-memory cache hydrated
 * from disk" without a hand-rolled cache.
 *
 * ## 3-state defaults (`contains`)
 *
 * Two boolean prefs (`recordHistory`, `requestDesktopSite`) are tri-state on
 * iOS: **absent** means "use the default" while a stored `false` means the user
 * explicitly turned it off. Swift expresses this as
 * `object(forKey:) != nil ? bool(forKey:) : default`. [contains] is the direct
 * port of `object(forKey:) != nil`, so callers can reproduce that branch
 * verbatim:
 *
 * ```kotlin
 * if (!appPreferences.contains(AppPreferences.RECORD_HISTORY_KEY)) true
 * else appPreferences.getBoolean(AppPreferences.RECORD_HISTORY_KEY, true)
 * ```
 *
 * ## Keys
 *
 * The string key constants are the single source of truth, kept byte-identical
 * to the Swift `*Key` constants so prefs written by either layer line up. They
 * intentionally live here (not on the higher-level enums) so the persistence
 * layer owns the wire format.
 *
 * ## Threading
 *
 * Reads are synchronous and thread-safe ([SharedPreferences] guarantees this).
 * Writes use [SharedPreferences.Editor.apply] (async, in-memory-immediate,
 * disk-eventually) which matches `UserDefaults.set`'s fire-and-forget semantics;
 * the value is visible to subsequent reads immediately. A [SharedPreferences]
 * instance is a process-wide singleton per name, so a single [AppPreferences]
 * should be constructed once (in `ZzApplication`) and shared.
 */
class AppPreferences(prefs: SharedPreferences) {

    /** Convenience constructor resolving the canonical [SharedPreferences] file. */
    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
    )

    private val prefs: SharedPreferences = prefs

    // --- Existence (port of UserDefaults `object(forKey:) != nil`) --------------

    /**
     * `true` when a value has been explicitly stored for [key].
     *
     * Direct port of Swift's `UserDefaults.standard.object(forKey:) != nil`,
     * used to distinguish "never set" (→ default) from an explicit `false` for
     * the tri-state boolean prefs.
     */
    fun contains(key: String): Boolean = prefs.contains(key)

    // --- String (port of `string(forKey:)`) ------------------------------------

    /**
     * The stored string for [key], or `null` when absent. Mirrors
     * `UserDefaults.standard.string(forKey:)` (which also returns `nil` for a
     * missing key). The default of `null` is only returned when the key is
     * genuinely absent.
     */
    fun getString(key: String): String? = prefs.getString(key, null)

    /** Stores [value] for [key], or removes the key when [value] is `null`. */
    fun putString(key: String, value: String?) {
        prefs.edit().apply {
            if (value == null) remove(key) else putString(key, value)
            apply()
        }
    }

    // --- Boolean (port of `bool(forKey:)`) --------------------------------------

    /**
     * The stored boolean for [key], or [default] when absent. Note that
     * `UserDefaults.bool(forKey:)` returns `false` for a missing key; callers
     * that need tri-state semantics must gate on [contains] first (see class
     * docs) — this method only substitutes [default] when the key is absent.
     */
    fun getBoolean(key: String, default: Boolean): Boolean =
        if (prefs.contains(key)) prefs.getBoolean(key, default) else default

    /** Stores [value] for [key]. */
    fun putBoolean(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).apply()
    }

    // --- Removal ----------------------------------------------------------------

    /** Removes [key]; subsequent [contains] returns `false`. */
    fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }

    companion object {
        /**
         * Name of the backing [SharedPreferences] file. Distinct from the
         * DataStore file used by the Settings screen so the two layers never
         * race over the same store.
         */
        const val PREFS_NAME = "surf.zz.app_preferences"

        // --- UserDefaults key constants ----------------------------------------
        //
        // Kept byte-identical to the Swift `*Key` constants in
        // SearchEngine.swift (`SearchPreferences` / `BrowserPreferences`).

        /** `SearchPreferences.engineKey` — selected built-in [SearchEngine] raw value. */
        const val ENGINE_KEY = "searchEngine"

        /** `SearchPreferences.customTemplateKey` — the user's custom `%s` template. */
        const val CUSTOM_TEMPLATE_KEY = "customSearchTemplate"

        /** `SearchPreferences.keywordEnginesKey` — JSON-encoded `List<KeywordEngine>`. */
        const val KEYWORD_ENGINES_KEY = "keywordEngines"

        /** `BrowserPreferences.newWindowPolicyKey` — `NewWindowPolicy` raw value. */
        const val NEW_WINDOW_POLICY_KEY = "newWindowPolicy"

        /** `BrowserPreferences.recordHistoryKey` — tri-state; default `true`. */
        const val RECORD_HISTORY_KEY = "recordHistory"

        /** `BrowserPreferences.requestDesktopSiteKey` — tri-state; default `false`. */
        const val REQUEST_DESKTOP_SITE_KEY = "requestDesktopSite"
    }
}
