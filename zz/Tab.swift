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

    var isBlank: Bool { currentURL.isEmpty }

    @ObservationIgnored
    private var observations: [NSKeyValueObservation] = []

    @ObservationIgnored
    private var pendingScrollRestore: CGPoint?

    @ObservationIgnored
    private var lastScrollOffset: CGPoint = .zero

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
        if !url.isEmpty, let target = URLNormalizer.resolve(url) {
            if scrollOffset != .zero { pendingScrollRestore = scrollOffset }
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

    func didFinishNavigation() {
        guard let pending = pendingScrollRestore else { return }
        pendingScrollRestore = nil
        #if !os(macOS)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.webView.scrollView.setContentOffset(pending, animated: false)
        }
        #endif
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
        webView.reload()
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
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.completeHTTPAuthChallenge(
                key: key,
                protectionSpace: protectionSpace,
                disposition: .cancelAuthenticationChallenge,
                credential: nil
            )
        })
        alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak alert] _ in
            let username = alert?.textFields?.first?.text ?? ""
            let password = alert?.textFields?.dropFirst().first?.text ?? ""
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
                    if urlString != "about:blank" {
                        self.history?.record(url: urlString, title: self.title)
                    }
                    self.notifyPersistenceChanged()
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let t = view.title
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.title = t
                    if !self.currentURL.isEmpty, self.currentURL != "about:blank" {
                        self.history?.record(url: self.currentURL, title: t)
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
                    // Keep the pre-termination offset when WebContent resets to zero.
                    guard offset != .zero else { return }
                    self?.lastScrollOffset = offset
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak owner] in
            owner?.didFinishNavigation()
        }
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

    enum CodingKeys: String, CodingKey { case id, url, title, scrollX, scrollY }

    init(_ tab: Tab) {
        self.id = tab.id
        self.url = tab.currentURL
        self.title = tab.title
        self.scrollX = Double(tab.scrollOffset.x)
        self.scrollY = Double(tab.scrollOffset.y)
    }

    init(id: UUID, url: String, title: String?,
         scrollX: Double = 0, scrollY: Double = 0) {
        self.id = id
        self.url = url
        self.title = title
        self.scrollX = scrollX
        self.scrollY = scrollY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        scrollX = try c.decodeIfPresent(Double.self, forKey: .scrollX) ?? 0
        scrollY = try c.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0
    }
}
