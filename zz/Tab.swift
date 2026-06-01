import SwiftUI
import WebKit
import Observation
import UniformTypeIdentifiers
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct HTTPAuthKey: Hashable {
    let host: String
    let port: Int
    let realm: String
    let method: String
    let protocolName: String

    init(_ protectionSpace: URLProtectionSpace) {
        host = protectionSpace.host
        port = protectionSpace.port
        realm = protectionSpace.realm ?? ""
        method = protectionSpace.authenticationMethod
        protocolName = protectionSpace.protocol ?? ""
    }

    var account: String {
        [protocolName, host, String(port), realm, method]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: "|")
    }
}

private struct StoredHTTPAuthCredential: Codable {
    var user: String
    var password: String
}

private enum HTTPAuthCredentialStore {
    private static let service = "surf.zz.http-auth"

    static func credential(for key: HTTPAuthKey) -> URLCredential? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredHTTPAuthCredential.self, from: data) else {
            return nil
        }
        return URLCredential(user: stored.user, password: stored.password, persistence: .permanent)
    }

    static func set(_ credential: URLCredential, for key: HTTPAuthKey) {
        guard let user = credential.user,
              let password = credential.password,
              !(user.isEmpty && password.isEmpty),
              let data = try? JSONEncoder().encode(StoredHTTPAuthCredential(user: user, password: password)) else {
            return
        }

        // Avoid churning the keychain (delete + add) on every auth-protected
        // navigation when reusing an already-stored, unchanged credential.
        if let existing = Self.credential(for: key),
           existing.user == user, existing.password == password {
            return
        }

        remove(for: key)
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func remove(for key: HTTPAuthKey) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private static func baseQuery(for key: HTTPAuthKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
    }
}

/// Pure page-zoom level math: defaults, clamping, and stepping. Kept free of any
/// WebKit/UI state so the clamp/step behavior is unit-testable in isolation.
nonisolated enum PageZoom {
    static let defaultLevel: Double = 1.0
    static let minLevel: Double = 0.5
    static let maxLevel: Double = 3.0
    static let step: Double = 0.1

    static func clamp(_ level: Double) -> Double {
        level.clamped(to: minLevel...maxLevel)
    }

    static func zoomedIn(_ level: Double) -> Double {
        clamp(level + step)
    }

    static func zoomedOut(_ level: Double) -> Double {
        clamp(level - step)
    }
}

@MainActor
@Observable
final class Tab {
    let id: UUID
    let webView: WKWebView

    var currentURL: String
    var title: String?
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isLoading: Bool = false
    var estimatedProgress: Double = 0

    // NB: never assign to pageZoom inside this didSet -- under @Observable that
    // re-enters the setter and didSet fires on every assignment, causing infinite
    // recursion -> stack overflow at launch. Clamping is done at the assignment
    // sites instead (init and BrowserStore.zoomIn/Out/resetFocused).
    var pageZoom: Double = PageZoom.defaultLevel {
        didSet {
            guard pageZoom != oldValue else { return }
            applyPageZoom()
            notifyPersistenceChanged()
        }
    }

    var isBlank: Bool { currentURL.isEmpty }

    @ObservationIgnored
    private var observations: [NSKeyValueObservation] = []

    @ObservationIgnored
    private var pendingScrollRestore: CGPoint?

    @ObservationIgnored
    private var lastScrollOffset: CGPoint = .zero

    // True while a navigation is in flight (or the WebContent process is being
    // recovered). WebKit resets contentOffset to zero during these transitions,
    // so zero offsets are ignored only while this is set -- a genuine user
    // scroll back to the top while the page is settled still updates the offset.
    @ObservationIgnored
    private var isNavigationInFlight: Bool = false

    // True while performing the initial programmatic load of a restored tab.
    // Suppresses history recording so session restore does not reorder/re-stamp
    // the history LRU. Cleared after the first didFinish.
    @ObservationIgnored
    private var isRestoring: Bool = false

    @ObservationIgnored
    private var httpAuthCredentials: [HTTPAuthKey: URLCredential] = [:]

    @ObservationIgnored
    private var lastHTTPAuthCredentialsTried: [HTTPAuthKey: URLCredential] = [:]

    @ObservationIgnored
    private var pendingHTTPAuthCompletions:
        [HTTPAuthKey: [(URLSession.AuthChallengeDisposition, URLCredential?) -> Void]] = [:]

    @ObservationIgnored
    private let uiDelegate = SameWindowUIDelegate()

    @ObservationIgnored
    private let navDelegate = TabNavigationDelegate()

    @ObservationIgnored
    private weak var history: HistoryStore?

    @ObservationIgnored
    var onPersistenceChange: (@MainActor () -> Void)?

    @ObservationIgnored
    var onNewWindowRequest: (@MainActor (WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?

    @ObservationIgnored
    var onCloseWindowRequest: (@MainActor () -> Void)?

    init(id: UUID = UUID(), url: String = "", title: String? = nil,
         scrollOffset: CGPoint = .zero,
         pageZoom: Double = PageZoom.defaultLevel,
         configuration providedConfiguration: WKWebViewConfiguration? = nil,
         history: HistoryStore?) {
        self.id = id
        self.currentURL = url
        self.title = title
        self.history = history

        let config = providedConfiguration ?? WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        #if !os(macOS)
        config.allowsInlineMediaPlayback = true
        #endif

        // Avoid a 0x0 initial viewport before the first layout pass.
        #if os(macOS)
        self.webView = PaneDropRoutingWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: config
        )
        #else
        self.webView = NoDropWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: config
        )
        #endif
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.uiDelegate = uiDelegate
        self.webView.navigationDelegate = navDelegate
        #if !os(macOS)
        self.webView.isFindInteractionEnabled = true
        #endif
        #if !os(macOS)
        self.webView.scrollView.contentInsetAdjustmentBehavior = .never
        self.webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        // Match Safari on pages that lock or do not need scrolling.
        self.webView.scrollView.alwaysBounceVertical = false
        self.webView.scrollView.alwaysBounceHorizontal = false
        #endif

        navDelegate.owner = self
        uiDelegate.owner = self
        wire()
        // Restore the persisted zoom level. onPersistenceChange is still nil here,
        // so the didSet's save notification is a no-op during construction.
        self.pageZoom = PageZoom.clamp(pageZoom)
        applyPageZoom()
        if !url.isEmpty, let target = URLNormalizer.resolve(url) {
            if scrollOffset != .zero {
                pendingScrollRestore = scrollOffset
                lastScrollOffset = scrollOffset
            }
            // This initial load originates from session restore, not user
            // navigation: suppress history recording until the first didFinish.
            isRestoring = true
            isNavigationInFlight = true
            webView.load(URLRequest(url: target))
        }
    }


    func reload()    { webView.reload() }
    func forceReload() {
        if webView.url != nil {
            webView.reloadFromOrigin()
        } else if let target = URLNormalizer.resolve(currentURL) {
            let request = URLRequest(
                url: target,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 60
            )
            webView.load(request)
        }
    }
    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }
    func stop()      { webView.stopLoading() }

    func focusForBrowsing() {
        #if os(macOS)
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)
        }
        #else
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            if let contentView = webView.scrollView.subviews.first(where: { subview in
                NSStringFromClass(type(of: subview)).contains("WKContent")
            }) {
                contentView.becomeFirstResponder()
            } else {
                webView.becomeFirstResponder()
            }
        }
        #endif
    }

    func find() {
        #if !os(macOS)
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
        #else
        // WKWebView participates in the text-finder responder chain and shows its
        // built-in find bar. Make the web view first responder, then send the
        // showFindInterface action; the sender's tag selects the action.
        webView.window?.makeFirstResponder(webView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
        #endif
    }

    func go(to item: WKBackForwardListItem) { webView.go(to: item) }

    var backList:    [WKBackForwardListItem] { webView.backForwardList.backList }
    var forwardList: [WKBackForwardListItem] { webView.backForwardList.forwardList }

    func handleNewWindowRequest(
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction
    ) -> WKWebView? {
        // The owner (BrowserStore) handles every NewWindowPolicy itself:
        // sidebar/splitRight create and return a web view, samePane loads into
        // the source pane, and block suppresses the popup -- all returning nil
        // for the latter two on purpose. Only fall back to loading in the
        // source pane when there is genuinely no owner installed.
        guard let onNewWindowRequest else {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        return onNewWindowRequest(configuration, navigationAction)
    }

    func handleCloseWindowRequest() {
        onCloseWindowRequest?()
    }

    func load(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            currentURL = ""
            return
        }
        guard let target = URLNormalizer.resolve(trimmed) else { return }
        pendingScrollRestore = nil
        isNavigationInFlight = true
        // An explicit user load is genuine navigation: stop suppressing history
        // even if the restore's initial load has not finished yet.
        isRestoring = false
        currentURL = target.absoluteString
        notifyPersistenceChanged()
        webView.load(URLRequest(url: target))
    }

    var scrollOffset: CGPoint {
        #if !os(macOS)
        return lastScrollOffset
        #else
        return .zero
        #endif
    }

    /// Pushes the current `pageZoom` onto the web view. On macOS WKWebView exposes
    /// a native `pageZoom`; on iOS there is no public API before 16-era betas, so
    /// drive the CSS `zoom` on the document element instead, which survives until
    /// the next navigation (hence the re-apply in `didFinishNavigation`).
    func applyPageZoom() {
        #if os(macOS)
        webView.pageZoom = CGFloat(pageZoom)
        #else
        let level = pageZoom
        webView.evaluateJavaScript(
            "document.documentElement.style.zoom='\(level)';", completionHandler: nil)
        #endif
    }

    func didFinishNavigation() {
        isNavigationInFlight = false
        isRestoring = false
        // CSS zoom is reset by each navigation on iOS; macOS's native pageZoom
        // persists across loads but re-applying is harmless and keeps both paths
        // identical.
        applyPageZoom()
        guard let pending = pendingScrollRestore else { return }
        pendingScrollRestore = nil
        #if !os(macOS)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.webView.scrollView.setContentOffset(pending, animated: false)
        }
        #endif
    }

    func handleNavigationFailure() {
        // didFinishNavigation is the only other place these flags are cleared, so a
        // navigation that fails (DNS/connection error, error page, cancelled load,
        // user Stop) would otherwise leave them stuck true -- permanently suppressing
        // scroll-to-zero recording and, for a failed restore load, history recording.
        isNavigationInFlight = false
        isRestoring = false
        pendingScrollRestore = nil
    }

    private func notifyPersistenceChanged() {
        onPersistenceChange?()
    }

    func recoverFromTermination() {
        #if !os(macOS)
        if lastScrollOffset != .zero {
            pendingScrollRestore = lastScrollOffset
        }
        #endif
        isNavigationInFlight = true
        // reload() is a no-op when there is no committed back-forward item (e.g. the
        // process died during the initial provisional load), which would leave the
        // pane blank and isNavigationInFlight stuck true. Re-issue the original load
        // in that case so recovery actually navigates.
        if webView.url == nil, let target = URLNormalizer.resolve(currentURL) {
            webView.load(URLRequest(url: target))
        } else {
            webView.reload()
        }
    }

    func respondToHTTPAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        let key = HTTPAuthKey(protectionSpace)
        let storedCredential = HTTPAuthCredentialStore.credential(for: key)
        let proposedCredential = challenge.proposedCredential

        let failedPreviousCredential = challenge.previousFailureCount > 0
        if failedPreviousCredential {
            if let storedCredential,
               !credentialsMatch(storedCredential, proposedCredential),
               !credentialsMatch(storedCredential, lastHTTPAuthCredentialsTried[key]) {
                useHTTPAuthCredential(
                    storedCredential,
                    key: key,
                    protectionSpace: protectionSpace,
                    remember: true,
                    completionHandler: completionHandler
                )
                return
            }
            clearHTTPAuthCredential(for: key, protectionSpace: protectionSpace, removeStored: true)
        } else {
            lastHTTPAuthCredentialsTried.removeValue(forKey: key)

            if let credential = httpAuthCredentials[key] {
                useHTTPAuthCredential(
                    credential,
                    key: key,
                    protectionSpace: protectionSpace,
                    remember: false,
                    completionHandler: completionHandler
                )
                return
            }
            if let credential = storedCredential {
                useHTTPAuthCredential(
                    credential,
                    key: key,
                    protectionSpace: protectionSpace,
                    remember: true,
                    completionHandler: completionHandler
                )
                return
            }
            if let credential = URLCredentialStorage.shared.defaultCredential(for: protectionSpace) {
                useHTTPAuthCredential(
                    credential,
                    key: key,
                    protectionSpace: protectionSpace,
                    remember: false,
                    completionHandler: completionHandler
                )
                return
            }
            if let credential = proposedCredential {
                useHTTPAuthCredential(
                    credential,
                    key: key,
                    protectionSpace: protectionSpace,
                    remember: false,
                    completionHandler: completionHandler
                )
                return
            }
        }

        if var pending = pendingHTTPAuthCompletions[key] {
            pending.append(completionHandler)
            pendingHTTPAuthCompletions[key] = pending
            return
        }

        pendingHTTPAuthCompletions[key] = [completionHandler]
        #if !os(macOS)
        let host = protectionSpace.port > 0
            ? "\(protectionSpace.host):\(protectionSpace.port)"
            : protectionSpace.host
        let title = challenge.previousFailureCount > 0 ? "Sign In Failed" : "Sign In Required"
        let message: String
        if let realm = protectionSpace.realm, !realm.isEmpty {
            message = "\(host)\n\(realm)"
        } else {
            message = host
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Username"
            field.textContentType = .username
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Password"
            field.textContentType = .password
            field.isSecureTextEntry = true
        }
        // Capture self weakly so an open alert does not keep this Tab (and its
        // WKWebView) alive after the pane is closed. completionHandler is captured
        // directly as a fallback: if self is gone, pendingHTTPAuthCompletions died
        // with it, so answer WebKit here to avoid a hung challenge.
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            guard let self else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            self.completeHTTPAuthChallenge(
                key: key,
                protectionSpace: protectionSpace,
                disposition: .cancelAuthenticationChallenge,
                credential: nil
            )
        })
        alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self, weak alert] _ in
            let username = alert?.textFields?.first?.text ?? ""
            let password = alert?.textFields?.dropFirst().first?.text ?? ""
            guard let self else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // Treat an empty username/password as a cancel so a fumbled dialog
            // does not persist an empty credential that auto-fails each restart.
            guard !username.isEmpty || !password.isEmpty else {
                self.completeHTTPAuthChallenge(
                    key: key,
                    protectionSpace: protectionSpace,
                    disposition: .cancelAuthenticationChallenge,
                    credential: nil
                )
                return
            }
            let credential = URLCredential(
                user: username,
                password: password,
                persistence: .permanent
            )
            self.completeHTTPAuthChallenge(
                key: key,
                protectionSpace: protectionSpace,
                disposition: .useCredential,
                credential: credential
            )
        })

        guard let presenter = UIViewController.zzTopMostPresenter() else {
            completeHTTPAuthChallenge(
                key: key,
                protectionSpace: protectionSpace,
                disposition: .performDefaultHandling,
                credential: nil
            )
            return
        }
        presenter.present(alert, animated: true)
        #else
        completeHTTPAuthChallenge(
            key: key,
            protectionSpace: protectionSpace,
            disposition: .performDefaultHandling,
            credential: nil
        )
        #endif
    }

    private func useHTTPAuthCredential(
        _ credential: URLCredential,
        key: HTTPAuthKey,
        protectionSpace: URLProtectionSpace,
        remember: Bool,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        httpAuthCredentials[key] = credential
        lastHTTPAuthCredentialsTried[key] = credential
        if remember {
            HTTPAuthCredentialStore.set(credential, for: key)
        }
        URLCredentialStorage.shared.set(credential, for: protectionSpace)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: protectionSpace)
        completionHandler(.useCredential, credential)
    }

    private func completeHTTPAuthChallenge(
        key: HTTPAuthKey,
        protectionSpace: URLProtectionSpace,
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?
    ) {
        if disposition == .useCredential, let credential {
            httpAuthCredentials[key] = credential
            lastHTTPAuthCredentialsTried[key] = credential
            HTTPAuthCredentialStore.set(credential, for: key)
            URLCredentialStorage.shared.set(credential, for: protectionSpace)
            URLCredentialStorage.shared.setDefaultCredential(credential, for: protectionSpace)
        }
        let completions = pendingHTTPAuthCompletions.removeValue(forKey: key) ?? []
        for completion in completions {
            completion(disposition, credential)
        }
    }

    private func clearHTTPAuthCredential(
        for key: HTTPAuthKey,
        protectionSpace: URLProtectionSpace,
        removeStored: Bool
    ) {
        if let credential = httpAuthCredentials.removeValue(forKey: key) {
            URLCredentialStorage.shared.remove(credential, for: protectionSpace)
        }
        if let credential = URLCredentialStorage.shared.defaultCredential(for: protectionSpace) {
            URLCredentialStorage.shared.remove(credential, for: protectionSpace)
        }
        lastHTTPAuthCredentialsTried.removeValue(forKey: key)
        if removeStored {
            HTTPAuthCredentialStore.remove(for: key)
        }
    }

    private func credentialsMatch(_ lhs: URLCredential?, _ rhs: URLCredential?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.user == rhs.user && lhs.password == rhs.password
    }

    private func wire() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                let urlString = view.url?.absoluteString
                Task { @MainActor [weak self] in
                    guard let self, let urlString, !urlString.isEmpty else { return }
                    self.currentURL = urlString
                    if urlString != "about:blank", !self.isRestoring {
                        self.history?.record(url: urlString, title: self.title)
                    }
                    self.notifyPersistenceChanged()
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let t = view.title
                // Capture the URL atomically with the title: the separate url
                // observer's Task may not have updated self.currentURL yet, so
                // recording against self.currentURL could attribute this title to
                // the previous page. view.url is the page the title belongs to.
                let urlString = view.url?.absoluteString
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.title = t
                    let recordURL = urlString ?? self.currentURL
                    if !recordURL.isEmpty, recordURL != "about:blank", !self.isRestoring {
                        self.history?.record(url: recordURL, title: t)
                    }
                    self.notifyPersistenceChanged()
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                let v = view.canGoBack
                Task { @MainActor [weak self] in self?.canGoBack = v }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                let v = view.canGoForward
                Task { @MainActor [weak self] in self?.canGoForward = v }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                let v = view.isLoading
                Task { @MainActor [weak self] in self?.isLoading = v }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                let v = view.estimatedProgress
                Task { @MainActor [weak self] in self?.estimatedProgress = v }
            },
        ]
        #if !os(macOS)
        observations.append(
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                let offset = sv.contentOffset
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // WebKit resets contentOffset to zero while a navigation or
                    // process recovery is in flight; ignore those spurious zeros
                    // so we keep the pre-transition offset. Once the page has
                    // settled, a genuine user scroll back to (0,0) is recorded.
                    if offset == .zero, self.isNavigationInFlight { return }
                    self.lastScrollOffset = offset
                    // Schedule a debounced snapshot save so the scroll position is
                    // actually persisted; otherwise scrollX/scrollY only get written
                    // when some unrelated event happens to trigger a save, and the
                    // restored offset is usually stale (often pre-scroll .zero).
                    self.notifyPersistenceChanged()
                }
            }
        )
        #endif
    }
}

#if os(macOS)
final class PaneDropRoutingWebView: WKWebView {
    var dropHandler: PaneDropHandler?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForPaneDrops()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForPaneDrops()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard draggedPayload(from: sender.draggingPasteboard) != nil else {
            dropHandler?.end()
            return []
        }
        updateDrop(sender)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard draggedPayload(from: sender.draggingPasteboard) != nil else {
            dropHandler?.end()
            return []
        }
        updateDrop(sender)
        return operation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHandler?.end()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropHandler?.end()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropHandler?.end() }
        guard let payload = draggedPayload(from: sender.draggingPasteboard) else {
            return false
        }
        dropHandler?.perform(payload, dropLocation(from: sender), bounds.size)
        return true
    }

    private func updateDrop(_ sender: any NSDraggingInfo) {
        dropHandler?.update(dropLocation(from: sender), bounds.size)
    }

    private func registerForPaneDrops() {
        registerForDraggedTypes([
            .URL,
            .string,
            NSPasteboard.PasteboardType(UTType.json.identifier),
            NSPasteboard.PasteboardType(UTType.plainText.identifier),
            NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
        ])
    }

    private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
        switch draggedPayload(from: sender.draggingPasteboard) {
        case .parkedTab:
            return .move
        case .url:
            return .copy
        case nil:
            return []
        }
    }

    private func dropLocation(from sender: any NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

    private func draggedPayload(from pasteboard: NSPasteboard) -> PaneDropPayload? {
        if let tabID = draggedTabID(from: pasteboard) {
            return .parkedTab(tabID)
        }
        if let urlString = draggedURLString(from: pasteboard) {
            return .url(urlString)
        }
        return nil
    }

    private func draggedTabID(from pasteboard: NSPasteboard) -> UUID? {
        let jsonType = NSPasteboard.PasteboardType(UTType.json.identifier)
        guard let data = pasteboard.data(forType: jsonType) else { return nil }
        if let ref = try? JSONDecoder().decode(TabRef.self, from: data) {
            return ref.id
        }
        if let string = String(data: data, encoding: .utf8) {
            return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func draggedURLString(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first {
            return url.absoluteString
        }
        if let urlString = pasteboard.string(forType: .URL), !urlString.isEmpty {
            return DroppedURL.string(fromText: urlString)
        }
        if let string = pasteboard.string(forType: .string),
           let urlString = DroppedURL.string(fromText: string) {
            return urlString
        }
        return nil
    }
}
#endif

#if !os(macOS)
/// WebKit hooks for pane drops and stuck image-analysis deferrers.
private final class NoDropWebView: WKWebView {
    override var pasteConfiguration: UIPasteConfiguration? {
        get { nil }
        set { }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        false
    }

    override func paste(itemProviders: [NSItemProvider]) { }

    override func addInteraction(_ interaction: any UIInteraction) {
        if interaction is UIDropInteraction { return }
        super.addInteraction(interaction)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sanitizeWebKitSubviews()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sanitizeWebKitSubviews()
    }

    private func sanitizeWebKitSubviews() {
        stripDropInteractions()
        removeImageAnalysisDeferrers()
        Self.installPasteGuard(on: self)
    }

    private func stripDropInteractions() {
        for view in [scrollView] + scrollView.subviews + [self] {
            for interaction in view.interactions where interaction is UIDropInteraction {
                view.removeInteraction(interaction)
            }
        }
    }

    private func removeImageAnalysisDeferrers() {
        Self.removeImageAnalysisDeferrers(in: scrollView)
    }

    private static func removeImageAnalysisDeferrers(in view: UIView) {
        if let recognizers = view.gestureRecognizers {
            for recognizer in recognizers where isImageAnalysisDeferrer(recognizer) {
                remove(recognizer, from: view)
            }
        }
        for subview in view.subviews {
            removeImageAnalysisDeferrers(in: subview)
        }
    }

    private static func remove(_ recognizer: UIGestureRecognizer, from view: UIView) {
        switch recognizer.state {
        case .possible, .failed, .cancelled:
            view.removeGestureRecognizer(recognizer)
        default:
            DispatchQueue.main.async { [weak view, weak recognizer] in
                guard let view, let recognizer,
                      recognizer.view === view else { return }
                view.removeGestureRecognizer(recognizer)
            }
        }
    }

    private static func isImageAnalysisDeferrer(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer.name?.localizedCaseInsensitiveContains("image analysis") == true {
            return true
        }
        return String(describing: recognizer)
            .localizedCaseInsensitiveContains("Deferrer for image analysis")
    }

    private static func installPasteGuard(on webView: WKWebView) {
        guard let target = webView.scrollView.subviews.first(where: { sub in
            NSStringFromClass(type(of: sub)).contains("WKContent")
        }) else { return }

        if NSStringFromClass(type(of: target)).hasPrefix("_ZZ_NoDropPaste_") {
            target.pasteConfiguration = nil
            return
        }

        let originalClass: AnyClass = type(of: target)
        let newClassName = "_ZZ_NoDropPaste_" + NSStringFromClass(originalClass)
        if let existing = NSClassFromString(newClassName) {
            object_setClass(target, existing)
            target.pasteConfiguration = nil
            return
        }
        guard let newClass = objc_allocateClassPair(originalClass, newClassName, 0) else { return }

        let pasteSelector = NSSelectorFromString("pasteItemProviders:")
        let pasteBlock: @convention(block) (Any, [NSItemProvider]) -> Void = { _, _ in }
        class_addMethod(newClass, pasteSelector,
                        imp_implementationWithBlock(pasteBlock), "v@:@")

        let canPasteSelector = NSSelectorFromString("canPasteItemProviders:")
        let canPasteBlock: @convention(block) (Any, [NSItemProvider]) -> Bool = { _, _ in false }
        class_addMethod(newClass, canPasteSelector,
                        imp_implementationWithBlock(canPasteBlock), "c@:@")

        objc_registerClassPair(newClass)
        object_setClass(target, newClass)
        target.pasteConfiguration = nil
    }
}
#endif

#if !os(macOS)
private extension UIViewController {
    static func zzTopMostPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        let activeWindow = scenes
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        let fallbackWindow = scenes
            .flatMap(\.windows)
            .first { !$0.isHidden }

        return (activeWindow ?? fallbackWindow)?.rootViewController?.zzTopMostPresented()
    }

    func zzTopMostPresented() -> UIViewController {
        if let presentedViewController {
            return presentedViewController.zzTopMostPresented()
        }
        if let navigation = self as? UINavigationController,
           let visible = navigation.visibleViewController {
            return visible.zzTopMostPresented()
        }
        if let tabBar = self as? UITabBarController,
           let selected = tabBar.selectedViewController {
            return selected.zzTopMostPresented()
        }
        return self
    }
}
#endif

private final class TabNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var owner: Tab?
    private let httpAuthenticationMethods: Set<String> = [
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodNTLM,
        NSURLAuthenticationMethodNegotiate,
    ]

    // Downloads in progress, retained for the lifetime of their transfer. The
    // delegate keeps a strong reference to each WKDownloadDelegate so it stays
    // alive until the download completes or fails.
    private var downloadDelegates: [ObjectIdentifier: DownloadDelegate] = [:]

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak owner] in
            owner?.didFinishNavigation()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak owner] in
            owner?.handleNavigationFailure()
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Task { @MainActor [weak owner] in
            owner?.handleNavigationFailure()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Treat a response WebKit cannot render inline -- or one the server
        // explicitly marks as an attachment -- as a download. Without this the
        // load is silently cancelled and the file is dropped.
        if !navigationResponse.canShowMIMEType || isAttachment(navigationResponse.response) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    private func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else {
            return false
        }
        return disposition.range(of: "attachment", options: .caseInsensitive) != nil
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        attach(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        attach(download)
    }

    private func attach(_ download: WKDownload) {
        let delegate = DownloadDelegate { [weak self] finished in
            self?.downloadDelegates.removeValue(forKey: ObjectIdentifier(finished))
        }
        downloadDelegates[ObjectIdentifier(download)] = delegate
        download.delegate = delegate
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        guard httpAuthenticationMethods.contains(protectionSpace.authenticationMethod) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        Task { @MainActor [weak owner] in
            guard let owner else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            owner.respondToHTTPAuthenticationChallenge(
                challenge,
                completionHandler: completionHandler
            )
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak owner] in
            owner?.recoverFromTermination()
        }
    }
}

/// Picks a destination for a WKDownload and reports completion back to its owner.
private final class DownloadDelegate: NSObject, WKDownloadDelegate {
    private let onFinish: (WKDownload) -> Void

    init(onFinish: @escaping (WKDownload) -> Void) {
        self.onFinish = onFinish
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let filename = sanitized(suggestedFilename)
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else {
                completionHandler(nil)
                return
            }
            // The save panel guarantees the user chose this path; remove any
            // stale file there since WKDownload refuses an existing destination.
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
        #else
        guard let directory = try? FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            completionHandler(nil)
            return
        }
        completionHandler(uniqueDestination(in: directory, filename: filename))
        #endif
    }

    func downloadDidFinish(_ download: WKDownload) {
        onFinish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        onFinish(download)
    }

    private func sanitized(_ suggestedFilename: String) -> String {
        let name = suggestedFilename
            .components(separatedBy: CharacterSet(charactersIn: "/\\")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "download" : name
    }

    #if !os(macOS)
    private func uniqueDestination(in directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 1
        while true {
            let suffix = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let next = directory.appendingPathComponent(suffix)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
            index += 1
        }
    }
    #endif
}

/// Routes new-window requests into app-owned panes instead of letting WebKit spawn windows.
private final class SameWindowUIDelegate: NSObject, WKUIDelegate {
    weak var owner: Tab?

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        owner?.handleNewWindowRequest(
            configuration: configuration,
            navigationAction: navigationAction
        )
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.handleCloseWindowRequest()
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    #if !os(macOS)
    func webView(_ webView: WKWebView,
                 requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
    #endif

    #if os(macOS)
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    #endif
}

// MARK: - Persistence

struct TabRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var url: String
    var title: String?
    var scrollX: Double
    var scrollY: Double
    var pageZoom: Double

    enum CodingKeys: String, CodingKey { case id, url, title, scrollX, scrollY, pageZoom }

    init(_ tab: Tab) {
        self.id = tab.id
        self.url = tab.currentURL
        self.title = tab.title
        self.scrollX = Double(tab.scrollOffset.x)
        self.scrollY = Double(tab.scrollOffset.y)
        self.pageZoom = tab.pageZoom
    }

    init(id: UUID, url: String, title: String?,
         scrollX: Double = 0, scrollY: Double = 0,
         pageZoom: Double = PageZoom.defaultLevel) {
        self.id = id
        self.url = url
        self.title = title
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.pageZoom = pageZoom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        scrollX = try c.decodeIfPresent(Double.self, forKey: .scrollX) ?? 0
        scrollY = try c.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0
        pageZoom = try c.decodeIfPresent(Double.self, forKey: .pageZoom) ?? PageZoom.defaultLevel
    }
}
