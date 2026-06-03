package surf.zz.browser.auth

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import surf.zz.persistence.ZzJson

/**
 * Encrypted, persistent store for HTTP-auth credentials keyed by
 * [HttpAuthKey.account].
 *
 * Ports `HTTPAuthCredentialStore` from `ios/zz/Tab.swift:72`. On iOS this is a
 * Keychain-backed (`SecItem*`) generic-password store, one item per protection
 * space, with the credential payload serialized as JSON. On Android the Keychain
 * has no direct equivalent, so we use Jetpack Security's
 * [EncryptedSharedPreferences]: each [HttpAuthKey.account] string is a preference
 * key, and the value is the JSON encoding of a [StoredHttpAuthCredential].
 *
 * The master key is held in the Android Keystore (hardware-backed where the
 * device supports it) and is created with `AES256_GCM`, which is the closest
 * analog to the iOS `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` posture: the
 * encrypted blob never leaves the device and is not included in cloud backups of
 * the file (the key is non-exportable).
 *
 * ### CRUD parity with iOS
 * - [credential] <- `static func credential(for:)`
 * - [set]        <- `static func set(_:for:)`
 * - [remove]     <- `static func remove(for:)`
 *
 * ### Relationship to WebView's own credential cache
 * `WebView.setHttpAuthUsernamePassword(host, realm, user, password)` (and its
 * deprecated global `WebViewDatabase` equivalent) is a *fast in-process cache*
 * the platform consults before delivering `onReceivedHttpAuthRequest`. It is the
 * Android analog of iOS's `URLCredentialStorage` and is intentionally NOT the
 * durable store: it is per-WebView, opaque, and not encrypted to our standard.
 * This class is the durable, encrypted source of truth (the Keychain analog);
 * the caller ([Tab]) primes the WebView cache from here and re-saves here on a
 * successful prompt, exactly as the iOS code mirrors writes into both the
 * Keychain and `URLCredentialStorage`.
 *
 * All public methods are safe to call from the main thread: the underlying
 * `SharedPreferences` reads are served from an in-memory map after the (one-time)
 * load, and writes use `commit()` so a credential saved immediately before a
 * process suspend is durable (matching the synchronous `SecItemAdd`).
 */
class HttpAuthCredentialStore private constructor(
    private val prefs: SharedPreferences,
) {
    /**
     * Returns the stored credential for [key], or `null` if none is stored or the
     * stored value cannot be decoded.
     *
     * Mirrors Swift `credential(for:)`: a `SecItemCopyMatching` miss or a JSON
     * decode failure both yield `nil`.
     */
    fun credential(key: HttpAuthKey): StoredHttpAuthCredential? {
        val raw = prefs.getString(key.account, null) ?: return null
        return runCatching { ZzJson.decodeFromString<StoredHttpAuthCredential>(raw) }
            .getOrNull()
    }

    /**
     * Persists [credential] for [key].
     *
     * Faithfully ports Swift `set(_:for:)`:
     *  - An entirely empty credential (both user and password empty) is dropped
     *    rather than stored, so a fumbled prompt never persists a blank identity
     *    that auto-fails on each restart. (Swift guards `!(user.isEmpty &&
     *    password.isEmpty)`.)
     *  - If the stored credential already matches, this is a no-op. iOS does this
     *    to avoid churning the Keychain (delete + add) on every auth-protected
     *    navigation that reuses an unchanged credential; here it avoids a
     *    redundant encrypt + `commit()`.
     */
    fun set(credential: StoredHttpAuthCredential, key: HttpAuthKey) {
        if (credential.user.isEmpty() && credential.password.isEmpty()) return

        val existing = credential(key)
        if (existing != null &&
            existing.user == credential.user &&
            existing.password == credential.password
        ) {
            return
        }

        val encoded = runCatching { ZzJson.encodeToString(credential) }.getOrElse { error ->
            // Mirrors Swift's `try? JSONEncoder().encode(...)` early-return: an
            // encode failure simply skips the write rather than crashing.
            Log.w(TAG, "Failed to encode HTTP-auth credential", error)
            return
        }
        prefs.edit().putString(key.account, encoded).commit()
    }

    /**
     * Removes any stored credential for [key]. A no-op if none is stored, matching
     * Swift `remove(for:)` (`SecItemDelete` on a missing item is benign).
     */
    fun remove(key: HttpAuthKey) {
        prefs.edit().remove(key.account).commit()
    }

    companion object {
        private const val TAG = "HttpAuthCredentialStore"

        /**
         * Preferences file name. Mirrors the iOS Keychain `service`
         * (`"surf.zz.http-auth"`) used to scope this store's items; on Android the
         * service-scoping is achieved by isolating these credentials in their own
         * encrypted preferences file.
         */
        private const val PREFS_FILE = "surf.zz.http-auth"

        /**
         * Builds the store, creating (or reusing) the Android Keystore master key
         * and opening the encrypted preferences file.
         *
         * Performs disk + Keystore I/O, so call off the main thread once at startup
         * (e.g. from `ZzApplication` on `Dispatchers.IO`) and share the singleton.
         */
        fun create(context: Context): HttpAuthCredentialStore {
            val appContext = context.applicationContext
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                appContext,
                PREFS_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            return HttpAuthCredentialStore(prefs)
        }
    }
}
