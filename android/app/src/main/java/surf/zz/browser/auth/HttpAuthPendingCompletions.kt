package surf.zz.browser.auth

/**
 * A single HTTP-auth credential pair (user + password), the Android analog of the
 * iOS `URLCredential` carried through an auth challenge completion. A `null`
 * completion argument means "cancel" (no credential); a non-null value means
 * "proceed" with these credentials.
 */
data class HttpAuthCredential(
    val user: String,
    val password: String,
)

/**
 * Reference-typed holder for the completion handlers queued against a single
 * in-flight auth prompt.
 *
 * On Android, WebView delivers each HTTP-auth challenge through its own
 * `WebViewClient.onReceivedHttpAuthRequest` callback (one `HttpAuthHandler` per
 * challenge). Multiple challenges for the same protection space (host/port/realm)
 * share one on-screen dialog: the first challenge creates the dialog and registers
 * here, and every later challenge for that space only appends its handler here
 * without spawning another dialog. The dialog's button actions capture this box
 * strongly, so it (and every queued handler) survives even if the owning [Tab] is
 * torn down while the dialog is still on screen. Without this, the second and later
 * challenges -- which never create their own dialog -- would be orphaned when the
 * Tab's map died, hanging those WebView challenges until they time out.
 *
 * Each completion is a single lambda taking a nullable [HttpAuthCredential]:
 *   - non-null  -> proceed with these credentials
 *   - null      -> cancel the challenge
 *
 * There is no deterministic `deinit` on Android; [Tab.close] drains every pending
 * box explicitly with a cancel (`null`). [drain] is idempotent, so a later drain
 * (e.g. a fallback firing after the dialog already answered, or teardown after a
 * normal answer) is a harmless no-op rather than a double invocation.
 */
class HttpAuthPendingCompletions(
    completion: (HttpAuthCredential?) -> Unit,
) {
    private var completions: MutableList<(HttpAuthCredential?) -> Unit> = mutableListOf(completion)
    private var answered = false

    fun append(completion: (HttpAuthCredential?) -> Unit) {
        completions.add(completion)
    }

    /**
     * Answers every queued handler exactly once with [credential] and drops the
     * references, so a later drain (e.g. the fallback firing after this box already
     * answered, or a teardown) is a no-op rather than a double invocation.
     */
    fun drain(credential: HttpAuthCredential?) {
        if (answered) return
        answered = true
        val pending = completions
        completions = mutableListOf()
        for (completion in pending) {
            completion(credential)
        }
    }
}
