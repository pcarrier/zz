package surf.zz.search

import android.net.Uri
import surf.zz.persistence.ZzJson
import surf.zz.prefs.AppPreferences
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

/**
 * Selected-engine / custom-template / keyword-engine accessors plus search-URL
 * building and template normalization.
 *
 * Ported from `ios/zz/SearchEngine.swift` (`nonisolated enum SearchPreferences`,
 * line 60). The Swift type is a namespace of `static` computed properties backed
 * by `UserDefaults.standard`; on Android it is an `object` layered over the
 * scalar-preference façade [surf.zz.prefs.AppPreferences] (the synchronous
 * SharedPreferences key-value layer described in ANDROID_ARCH §3/§6).
 *
 * ## Wiring the backing store
 * Swift's `UserDefaults.standard` is an ambient process singleton; [AppPreferences]
 * is an ordinary instance that needs a `Context`. To keep this an `object`
 * namespace (1:1 with the Swift `enum`) while still using the real typed
 * [AppPreferences] API, the backing instance is injected once at startup via
 * [init]. [ZzApplication] / `MainActivity` calls `SearchPreferences.init(...)`
 * before any omnibox code runs; the sibling `BrowserPreferences` shares the same
 * [AppPreferences] instance.
 *
 * ## Threading
 * Like the Swift original these accessors are synchronous reads/writes. The
 * underlying [AppPreferences] is backed by `SharedPreferences`, which is
 * synchronous and thread-safe, mirroring iOS `UserDefaults`, so this file stays a
 * 1:1 structural port of the Swift code (no suspending / Flow-based API).
 *
 * ## Percent-encoding (important parity note)
 * The Swift code builds `searchQueryAllowed = .urlQueryAllowed` minus the
 * characters `&=?+#`, then `addingPercentEncoding(withAllowedCharacters:)`. On
 * Android this maps to [Uri.encode] with an `allow` set of the *unreserved* query
 * characters that remain — NOT `java.net.URLEncoder`, which form-encodes spaces as
 * `+` and would corrupt query strings substituted into a URL template.
 *
 * `Uri.encode(s, allow)` percent-encodes everything except the ASCII
 * alphanumerics and the characters listed in `allow`. So `allow` must enumerate
 * the non-alphanumeric members of `urlQueryAllowed` that survive removing
 * `&=?+#`. `CharacterSet.urlQueryAllowed` is RFC 3986's `pchar` plus `/` and `?`:
 *
 *   unreserved  : `-` `.` `_` `~`  (alphanumerics handled implicitly by Uri.encode)
 *   sub-delims  : `!` `$` `&` `'` `(` `)` `*` `+` `,` `;` `=`
 *   pchar extra : `:` `@`
 *   plus        : `/` `?`
 *
 * Removing `&`, `=`, `?`, `+`, `#` (`#` is not in the set to begin with) leaves:
 *
 *   `-._~ ! $ ' ( ) * , ; : @ /`
 *
 * which is the [SEARCH_QUERY_ALLOWED] string below. Spaces are NOT in the set, so
 * they correctly become `%20`.
 */
object SearchPreferences {
    const val ENGINE_KEY = "searchEngine"
    const val CUSTOM_TEMPLATE_KEY = "customSearchTemplate"
    const val KEYWORD_ENGINES_KEY = "keywordEngines"

    val defaultEngine: SearchEngine = SearchEngine.DUCK_DUCK_GO

    /** Built-in default template; non-null by the [SearchEngine] contract. */
    val defaultCustomTemplate: String = requireNotNull(defaultEngine.template)

    /**
     * Seeded so users discover the feature; safe because they share no keyword
     * with normal URLs/queries and only fire when a keyword + query is typed.
     */
    val defaultKeywordEngines: List<KeywordEngine> = listOf(
        KeywordEngine(keyword = "ddg", templateURL = "https://duckduckgo.com/?q=%s", title = "DuckDuckGo"),
        KeywordEngine(keyword = "g", templateURL = "https://www.google.com/search?q=%s", title = "Google"),
        KeywordEngine(keyword = "w", templateURL = "https://en.wikipedia.org/wiki/Special:Search?search=%s", title = "Wikipedia"),
    )

    /**
     * The non-alphanumeric characters of `CharacterSet.urlQueryAllowed` that
     * remain after removing `&=?+#`. Passed to [Uri.encode] as the `allow` set.
     * See the class doc for the derivation. Order is irrelevant to [Uri.encode].
     */
    private const val SEARCH_QUERY_ALLOWED = "-._~!$'()*,;:@/"

    private lateinit var prefs: AppPreferences

    /**
     * Wires the backing scalar-preference store. Must be called once at startup
     * (from [ZzApplication] / `MainActivity`) before any accessor is read.
     * Idempotent re-injection is allowed (e.g. test setup).
     */
    fun init(appPreferences: AppPreferences) {
        prefs = appPreferences
    }

    /**
     * Selected built-in engine.
     *
     * Getter: port of `UserDefaults.standard.string(forKey:).flatMap(SearchEngine.init) ?? defaultEngine`.
     * Setter: the write side of the Swift `@AppStorage(engineKey)` two-way binding —
     * stores the engine's [SearchEngine.rawValue] under [ENGINE_KEY], so the omnibox
     * hot path (which reads this getter) observes the change immediately.
     */
    var selectedEngine: SearchEngine
        get() = SearchEngine.fromRawValue(prefs.getString(ENGINE_KEY)) ?: defaultEngine
        set(value) {
            prefs.putString(ENGINE_KEY, value.rawValue)
        }

    /**
     * Custom `%s` template used when [selectedEngine] is [SearchEngine.CUSTOM].
     *
     * Getter: port of `UserDefaults.standard.string(forKey:) ?? defaultCustomTemplate`.
     * Setter: write side of the Swift `@AppStorage(customTemplateKey)` binding.
     */
    var customTemplate: String
        get() = prefs.getString(CUSTOM_TEMPLATE_KEY) ?: defaultCustomTemplate
        set(value) {
            prefs.putString(CUSTOM_TEMPLATE_KEY, value)
        }

    /**
     * User-defined keyword ("bang") engines. Persisted as JSON.
     *
     * When the key is absent (fresh/old install) we seed [defaultKeywordEngines];
     * an explicitly-stored array (even empty — the user removed all) decodes as-is.
     * A decode failure falls back to the defaults, matching the Swift `try?` path.
     */
    var keywordEngines: List<KeywordEngine>
        get() {
            val json = prefs.getString(KEYWORD_ENGINES_KEY) ?: return defaultKeywordEngines
            return try {
                ZzJson.decodeFromString<List<KeywordEngine>>(json)
            } catch (_: Exception) {
                defaultKeywordEngines
            }
        }
        set(value) {
            // Mirror `try? JSONEncoder().encode`; only persist on success.
            val json = try {
                ZzJson.encodeToString(value)
            } catch (_: Exception) {
                return
            }
            prefs.putString(KEYWORD_ENGINES_KEY, json)
        }

    /**
     * The template actually used for the selected engine.
     *
     * For [SearchEngine.CUSTOM] the stored custom template is normalized (and
     * falls back to [defaultCustomTemplate] when invalid). For the built-in
     * engines the engine's own template is used (the `?? defaultCustomTemplate`
     * is dead for built-ins but preserved 1:1 with the Swift `switch default`).
     */
    val activeTemplate: String
        get() = when (selectedEngine) {
            SearchEngine.CUSTOM -> normalizedTemplate(customTemplate) ?: defaultCustomTemplate
            else -> selectedEngine.template ?: defaultCustomTemplate
        }

    /**
     * Builds a search URL by substituting the percent-encoded [query] into
     * [template]'s `%s` placeholder. Returns `null` when the template is invalid
     * (no `%s`, empty) — callers (`WebView.loadUrl`) take a `String`, so this
     * returns `String?` rather than a parsed URL type (the Swift `URL?`).
     *
     * Note the substitution uses a plain string replace of every `%s`
     * occurrence, exactly like Swift's `replacingOccurrences(of:"%s",with:)`.
     */
    fun searchURL(query: String, template: String = activeTemplate): String? {
        val normalized = normalizedTemplate(template) ?: return null
        val encoded = Uri.encode(query, SEARCH_QUERY_ALLOWED)
        return normalized.replace("%s", encoded)
    }

    /**
     * Validates and normalizes a search template:
     *  - trims surrounding whitespace/newlines,
     *  - requires a non-empty result containing the `%s` placeholder,
     *  - prepends `https://` when the trimmed template has no URL scheme.
     *
     * Returns `null` for an empty template or one lacking `%s`.
     *
     * The scheme check mirrors Swift's `URL(string: trimmed)?.scheme != nil`
     * using `Uri.parse(trimmed).scheme` (a non-null, non-empty scheme means the
     * template already carries `scheme://…`).
     */
    fun normalizedTemplate(template: String): String? {
        val trimmed = template.trim()
        if (trimmed.isEmpty() || !trimmed.contains("%s")) return null
        val scheme = Uri.parse(trimmed).scheme
        if (!scheme.isNullOrEmpty()) return trimmed
        return "https://$trimmed"
    }
}
