package surf.zz.browser.auth

import kotlinx.serialization.Serializable
import java.util.Base64

/**
 * Composite identity for an HTTP authentication protection space.
 *
 * Ports `HTTPAuthKey` from `ios/zz/Tab.swift:12`. On iOS this is built from a
 * `URLProtectionSpace`; on Android the equivalent fields come off the
 * `android.webkit.WebView` `onReceivedHttpAuthRequest` host/realm plus the
 * request's scheme/port/auth-method (the `java.net.Authenticator` /
 * `URLProtectionSpace` concepts map onto these same five components).
 *
 * The five components must stay keyed identically to Swift so a credential
 * stored under one challenge is found again on the next: the ordering and the
 * base64-of-UTF-8 encoding of [account] are preserved verbatim.
 *
 * `realm`, `method`, and `scheme` default to the empty string, mirroring the
 * Swift `?? ""` fallbacks for the nullable protection-space fields.
 */
data class HttpAuthKey(
    val host: String,
    val port: Int,
    val realm: String = "",
    val method: String = "",
    val scheme: String = "",
) {
    /**
     * Stable account string used as the keystore/credential-store key.
     *
     * Mirrors Swift verbatim:
     * ```
     * [protocolName, host, String(port), realm, method]
     *     .map { Data($0.utf8).base64EncodedString() }
     *     .joined(separator: "|")
     * ```
     * `scheme` corresponds to Swift's `protocolName` and stays first so the key
     * is byte-for-byte the same composite identity. `java.util.Base64.getEncoder()`
     * uses the standard (non-URL-safe) alphabet, emits padding, and never wraps
     * lines, exactly matching `Data.base64EncodedString()`. (It is preferred over
     * `android.util.Base64` here so this pure key-derivation stays unit-testable on
     * the plain JVM; it is available from API 26, our minSdk.)
     */
    val account: String
        get() = listOf(scheme, host, port.toString(), realm, method)
            .joinToString("|") { component ->
                Base64.getEncoder().encodeToString(component.toByteArray(Charsets.UTF_8))
            }
}

/**
 * On-disk credential DTO for a single stored HTTP-auth identity.
 *
 * Ports Swift's `StoredHTTPAuthCredential` (`Codable struct { user; password }`).
 * Persisted as JSON under the credential store keyed by [HttpAuthKey.account].
 */
@Serializable
data class StoredHttpAuthCredential(
    val user: String,
    val password: String,
)
