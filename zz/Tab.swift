import SwiftUI
import WebKit
import Observation
import Combine
import UniformTypeIdentifiers
#if !os(macOS)
import UIKit
#endif

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
    private var resettingInsets = false

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []

    @ObservationIgnored
    private var pendingScrollRestore: CGPoint?

    /// Continuously mirrored from `webView.scrollView.contentOffset` so we
    /// have a pre-termination value to restore from when WebContent gets
    /// killed (the live `contentOffset` resets to .zero on kill).
    @ObservationIgnored
    private var lastScrollOffset: CGPoint = .zero

    @ObservationIgnored
    private let uiDelegate = SameWindowUIDelegate()

    @ObservationIgnored
    private let navDelegate = TabNavigationDelegate()

    @ObservationIgnored
    private weak var history: HistoryStore?

    @ObservationIgnored
    var onPersistenceChange: (@MainActor () -> Void)?

    init(id: UUID = UUID(), url: String = "", title: String? = nil,
         scrollOffset: CGPoint = .zero, history: HistoryStore?) {
        self.id = id
        self.currentURL = url
        self.title = title
        self.history = history

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        #if !os(macOS)
        config.allowsInlineMediaPlayback = true
        #endif

        // Initial frame chosen so the first layout pass uses a reasonable viewport
        // instead of 0×0 (where some sites snap to extreme mobile breakpoints).
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
        // Honor pages that lock scrolling: only allow panning when there is
        // actually scrollable content. WKWebView defaults `alwaysBounce*` to
        // true, which lets users drag and rubber-band even on pages with
        // `overflow: hidden` or content shorter than the viewport.
        self.webView.scrollView.alwaysBounceVertical = false
        self.webView.scrollView.alwaysBounceHorizontal = false
        #endif

        navDelegate.owner = self
        wire()
        if !url.isEmpty, let target = URLNormalizer.resolve(url) {
            if scrollOffset != .zero { pendingScrollRestore = scrollOffset }
            webView.load(URLRequest(url: target))
        }
    }


    func reload()    { webView.reload() }
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

    func load(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            currentURL = ""
            return
        }
        guard let target = URLNormalizer.resolve(trimmed) else { return }
        pendingScrollRestore = nil  // explicit nav cancels any pending restore
        currentURL = target.absoluteString
        notifyPersistenceChanged()
        webView.load(URLRequest(url: target))
    }

    var scrollOffset: CGPoint {
        #if !os(macOS)
        // Return the mirrored value: stays valid even if WebContent was
        // terminated and `scrollView.contentOffset` was reset to .zero.
        return lastScrollOffset
        #else
        return .zero
        #endif
    }

    func didFinishNavigation() {
        guard let pending = pendingScrollRestore else { return }
        pendingScrollRestore = nil
        #if !os(macOS)
        // Defer to let content lay out / images load before snapping the offset.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.webView.scrollView.setContentOffset(pending, animated: false)
        }
        #endif
    }

    private func notifyPersistenceChanged() {
        onPersistenceChange?()
    }

    /// Recover from a WebContent process termination: reload the page and
    /// restore the scroll offset we mirrored before the kill.
    func recoverFromTermination() {
        #if !os(macOS)
        if lastScrollOffset != .zero {
            pendingScrollRestore = lastScrollOffset
        }
        #endif
        webView.reload()
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
        // WebKit inserts a bottom contentInset equal to the keyboard height
        // when an input is focused — including when a HW keyboard is attached
        // and no software keyboard actually appears. Two layers of defense:
        //  • KVO on contentInset / scroll-indicator insets, snapping back to
        //    zero whenever we see them grow.
        //  • Notification-driven reset on keyboard-frame events, dispatched
        //    asynchronously so it runs after WebKit's own handlers.
        observations.append(
            webView.scrollView.observe(\.contentInset, options: [.new]) { [weak self] sv, _ in
                // UIScrollView KVO fires on the main thread.
                MainActor.assumeIsolated {
                    guard let self, !self.resettingInsets else { return }
                    if sv.contentInset != .zero {
                        self.resettingInsets = true
                        sv.contentInset = .zero
                        self.resettingInsets = false
                    }
                }
            }
        )
        observations.append(
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                let offset = sv.contentOffset
                MainActor.assumeIsolated {
                    // Skip zero updates: a WebContent termination wipes the
                    // offset to .zero and would otherwise clobber the
                    // pre-termination value we need for recovery.
                    guard offset != .zero else { return }
                    self?.lastScrollOffset = offset
                }
            }
        )
        observations.append(
            webView.scrollView.observe(\.verticalScrollIndicatorInsets, options: [.new]) { [weak self] sv, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.resettingInsets else { return }
                    if sv.verticalScrollIndicatorInsets != .zero {
                        self.resettingInsets = true
                        sv.verticalScrollIndicatorInsets = .zero
                        self.resettingInsets = false
                    }
                }
            }
        )

        let keyboardNotifications: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ]
        for name in keyboardNotifications {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        let sv = self.webView.scrollView
                        if sv.contentInset != .zero { sv.contentInset = .zero }
                        if sv.verticalScrollIndicatorInsets != .zero {
                            sv.verticalScrollIndicatorInsets = .zero
                        }
                        if sv.horizontalScrollIndicatorInsets != .zero {
                            sv.horizontalScrollIndicatorInsets = .zero
                        }
                    }
                }
                .store(in: &cancellables)
        }
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
private var inputAssistantAssociationKey: UInt8 = 0

/// WebKit customizations we can't get via public API:
///   • Refuse to host a `UIDropInteraction` on the WKWebView so SwiftUI's
///     tile-level `.onDrop` is what receives URL drops.
///   • Strip any drop interactions WebKit installs on the internal
///     `WKContentView` (a private subview of `scrollView`) and the scroll
///     view itself. Done on each `didMoveToWindow` and on every layout pass —
///     polling is cheap and avoids ObjC-runtime method swaps that can crash
///     when WebKit's own dispatch expects a particular IMP shape.
///   • Override `inputAccessoryView` on `WKContentView` (via a safe one-time
///     subclass swap) and blank `inputAssistantItem`, so focused web form
///     fields don't show the hardware-keyboard shortcut / mic bar.
///   • Remove WebKit's image-analysis deferral recognizer. It can get stuck
///     reporting an ended deferral on iPadOS when attached to the patched
///     content view, and it is not needed for browser pane interactions.
private final class NoDropWebView: WKWebView {
    override var pasteConfiguration: UIPasteConfiguration? {
        get { nil }
        set { }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        false
    }

    override func paste(itemProviders: [NSItemProvider]) {
        // URL drops are handled by the surrounding tile-level SwiftUI drop target.
    }

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
        // WebKit may install a drop interaction lazily; remove it if it
        // reappears after we've initially cleaned up.
        sanitizeWebKitSubviews()
    }

    private func sanitizeWebKitSubviews() {
        stripDropInteractions()
        removeImageAnalysisDeferrers()
        Self.silenceInputAccessory(of: self)
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

    private static func silenceInputAccessory(of webView: WKWebView) {
        guard let target = webView.scrollView.subviews.first(where: { sub in
            NSStringFromClass(type(of: sub)).contains("WKContent")
        }) else { return }

        // Already swapped on a prior window-move — nothing to do.
        if NSStringFromClass(type(of: target)).hasPrefix("_ZZ_NoInputAccessory_") {
            suppressKeyboardChrome(on: target)
            return
        }

        let originalClass: AnyClass = type(of: target)
        let newClassName = "_ZZ_NoInputAccessory_" + NSStringFromClass(originalClass)
        if let existing = NSClassFromString(newClassName) {
            object_setClass(target, existing)
            suppressKeyboardChrome(on: target)
            return
        }
        guard let newClass = objc_allocateClassPair(originalClass, newClassName, 0) else { return }
        let accessorySelector = #selector(getter: UIResponder.inputAccessoryView)
        let accessoryBlock: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        class_addMethod(newClass, accessorySelector,
                        imp_implementationWithBlock(accessoryBlock), "@@:")

        let assistantSelector = #selector(getter: UIResponder.inputAssistantItem)
        let assistantBlock: @convention(block) (AnyObject) -> UITextInputAssistantItem = { target in
            if let existing = objc_getAssociatedObject(
                target, &inputAssistantAssociationKey
            ) as? UITextInputAssistantItem {
                return existing
            }

            let item = UITextInputAssistantItem()
            item.leadingBarButtonGroups = []
            item.trailingBarButtonGroups = []
            item.allowsHidingShortcuts = true
            objc_setAssociatedObject(
                target,
                &inputAssistantAssociationKey,
                item,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return item
        }
        class_addMethod(newClass, assistantSelector,
                        imp_implementationWithBlock(assistantBlock), "@@:")

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
        suppressKeyboardChrome(on: target)
    }

    private static func suppressKeyboardChrome(on target: UIView) {
        target.pasteConfiguration = nil
        target.inputAssistantItem.leadingBarButtonGroups = []
        target.inputAssistantItem.trailingBarButtonGroups = []
        target.inputAssistantItem.allowsHidingShortcuts = true
        if target.isFirstResponder {
            target.reloadInputViews()
        }
    }
}
#endif

/// Forwards `didFinish` navigation events back to the owning `Tab` so it can
/// run post-load logic (e.g. restoring a saved scroll offset). Also reloads
/// the page when WebKit kills the WebContent process — without recovery, the
/// `WKWebView` keeps its frame but shows blank ("the panes go black").
private final class TabNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var owner: Tab?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak owner] in
            owner?.didFinishNavigation()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS terminates WebContent under memory pressure, especially with
        // multiple webviews loaded. Reload to bring the page back, and
        // restore the pre-termination scroll position via the cached
        // `lastScrollOffset` so the user lands where they left off.
        Task { @MainActor [weak owner] in
            owner?.recoverFromTermination()
        }
    }
}

/// `target="_blank"` and `window.open()` create a new web view by default.
/// We don't have a notion of separate web views per tab, so load the request
/// inside the originating tab instead.
private final class SameWindowUIDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
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
