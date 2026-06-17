package surf.zz.prefs

/**
 * Per-browser behavior preferences. Pure namespace over [AppPreferences] — the
 * Android analog of the iOS `BrowserPreferences` enum, which read/wrote
 * `UserDefaults.standard` synchronously.
 *
 * Port of `SearchEngine.swift:189` (`enum BrowserPreferences`). The keys and the
 * three-state default logic (unset vs. set) are preserved verbatim:
 *  - `newWindowPolicy` falls back to [NewWindowPolicy.SIDEBAR] when the stored
 *    raw value is missing or unrecognized.
 *  - `recordsHistory` defaults to **true** when the key has never been written
 *    (mirrors `object(forKey:) != nil` ? `bool(forKey:)` : `true`).
 *  - `requestsDesktopSite` defaults to **false** under the same unset-vs-set rule.
 *
 * Why `SharedPreferences.contains(...)` and not just `getBoolean(key, default)`:
 * the iOS code distinguishes "never set" from "explicitly set to false", because
 * `recordsHistory` defaults to `true` but `UserDefaults.bool` returns `false` for
 * an absent key. We replicate that by probing presence first, exactly like
 * `UserDefaults.object(forKey:) != nil`.
 */
object BrowserPreferences {
    const val NEW_WINDOW_POLICY_KEY = "newWindowPolicy"
    const val RECORD_HISTORY_KEY = "recordHistory"
    const val REQUEST_DESKTOP_SITE_KEY = "requestDesktopSite"

    val defaultNewWindowPolicy = NewWindowPolicy.SIDEBAR
    const val DEFAULT_REQUESTS_DESKTOP_SITE = false

    private lateinit var prefs: AppPreferences

    /**
     * Wires the backing scalar-preference store. Must be called once at startup
     * (from [surf.zz.ZzApplication] / `MainActivity`) before any accessor is read.
     * Idempotent re-injection is allowed (e.g. test setup). Shares the same
     * [AppPreferences] instance as the sibling `SearchPreferences`.
     */
    fun init(appPreferences: AppPreferences) {
        prefs = appPreferences
    }

    var newWindowPolicy: NewWindowPolicy
        get() {
            val raw = prefs.getString(NEW_WINDOW_POLICY_KEY)
            return raw?.let(NewWindowPolicy.Companion::fromRawValue) ?: defaultNewWindowPolicy
        }
        set(value) {
            prefs.putString(NEW_WINDOW_POLICY_KEY, value.rawValue)
        }

    var recordsHistory: Boolean
        get() {
            if (!prefs.contains(RECORD_HISTORY_KEY)) return true
            return prefs.getBoolean(RECORD_HISTORY_KEY, true)
        }
        set(value) {
            prefs.putBoolean(RECORD_HISTORY_KEY, value)
        }

    /**
     * Initial "Request Desktop Site" content mode applied to newly created tabs.
     * Restored tabs use their own persisted value instead (see `TabRecord`).
     */
    var requestsDesktopSite: Boolean
        get() {
            if (!prefs.contains(REQUEST_DESKTOP_SITE_KEY)) return DEFAULT_REQUESTS_DESKTOP_SITE
            return prefs.getBoolean(REQUEST_DESKTOP_SITE_KEY, DEFAULT_REQUESTS_DESKTOP_SITE)
        }
        set(value) {
            prefs.putBoolean(REQUEST_DESKTOP_SITE_KEY, value)
        }
}

/**
 * Policy for how a web page's "open in new window" (`window.open` / target=_blank /
 * `onCreateWindow`) request is handled. Port of `SearchEngine.swift:171`.
 *
 * [rawValue] reproduces the Swift `String` raw values (lowerCamelCase) so any
 * persisted value stays stable; [displayName] matches the iOS picker labels.
 */
enum class NewWindowPolicy(val rawValue: String, val displayName: String) {
    SIDEBAR("sidebar", "Park"),
    SPLIT_RIGHT("splitRight", "Split Right"),
    SAME_PANE("samePane", "Same Pane"),
    BLOCK("block", "Block");

    val id: String get() = rawValue

    companion object {
        fun fromRawValue(raw: String): NewWindowPolicy? =
            entries.firstOrNull { it.rawValue == raw }
    }
}
