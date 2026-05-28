import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Pane-level drops can originate from a browser URL drag or from a parked
/// sidebar tab.
enum PaneDropPayload {
    case url(String)
    case parkedTab(UUID)
}

struct PaneDropHandler {
    var update: (CGPoint, CGSize) -> Void
    var perform: (PaneDropPayload, CGPoint, CGSize) -> Void
    var end: () -> Void
}

/// Hosts a `WKWebView` that's owned externally (by a `Tab`), allowing the same
/// instance to move between locations without being torn down.
struct HostedWebView: View {
    let webView: WKWebView
    var onInteraction: (() -> Void)? = nil
    var dropHandler: PaneDropHandler? = nil
    var shouldHost: () -> Bool = { true }
    var layoutRevision: Int = 0

    var body: some View {
        GeometryReader { proxy in
            _Representable(
                webView: webView,
                onInteraction: onInteraction,
                dropHandler: dropHandler,
                shouldHost: shouldHost,
                layoutRevision: layoutRevision,
                layoutSize: proxy.size
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct _Representable {
    let webView: WKWebView
    let onInteraction: (() -> Void)?
    let dropHandler: PaneDropHandler?
    let shouldHost: () -> Bool
    let layoutRevision: Int
    let layoutSize: CGSize
}

#if canImport(UIKit)

extension _Representable: UIViewRepresentable {
    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.onInteraction = onInteraction
        container.shouldHost = shouldHost
        container.setLayoutRevision(layoutRevision)
        container.setLayoutSize(layoutSize)
        container.attach(webView)
        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        container.onInteraction = onInteraction
        container.shouldHost = shouldHost
        container.setLayoutRevision(layoutRevision)
        container.setLayoutSize(layoutSize)
        container.attach(webView)
    }

    static func dismantleUIView(_ container: ContainerView, coordinator: ()) {
        container.dismantle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContainerView, context: Context) -> CGSize? {
        // No intrinsic opinion — take whatever the parent proposes.
        nil
    }
}

extension _Representable {
    /// A passthrough container ensures the `WKWebView` always has the right parent,
    /// even after being yanked away by another `HostedWebView` and brought back.
    final class ContainerView: UIView {
        var onInteraction: (() -> Void)?
        var shouldHost: () -> Bool = { true }

        private var lastInteractionAt: CFTimeInterval = 0
        private weak var hostedWebView: WKWebView?
        private var fullscreenObservation: NSKeyValueObservation?
        private var layoutSize: CGSize = .zero
        private var layoutRevision: Int = 0
        private var rehostRequested = false
        private var deferredRefreshPending = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            clipsToBounds = true
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            refreshHostedLayout()
        }

        /// Observe touches via hit-testing rather than a gesture recognizer.
        /// `hitTest(_:with:)` is read-only — UIKit asks us "who should receive
        /// this touch?", we report the answer, and the touch then flows normally
        /// into WebKit's gesture system (including sub-iframe scroll routing).
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let result = super.hitTest(point, with: event)
            if countsAsClickToFocus(event), let r = result, r !== self {
                let now = CACurrentMediaTime()
                if now - lastInteractionAt > 0.1 {
                    lastInteractionAt = now
                    onInteraction?()
                }
            }
            return result
        }

        private func countsAsClickToFocus(_ event: UIEvent?) -> Bool {
            guard let event else { return false }
            switch event.type {
            case .touches, .presses:
                return true
            default:
                return false
            }
        }

        func setLayoutRevision(_ revision: Int) {
            guard layoutRevision != revision else { return }
            layoutRevision = revision
            rehostRequested = true
            setNeedsLayout()
            scheduleDeferredRefresh()
        }

        func setLayoutSize(_ size: CGSize) {
            let normalized = size.normalizedForPaneLayout
            guard layoutSize != normalized else {
                refreshHostedLayout()
                return
            }
            layoutSize = normalized
            setNeedsLayout()
            refreshHostedLayout()
            scheduleDeferredRefresh()
        }

        func attach(_ webView: WKWebView) {
            if hostedWebView !== webView {
                if let hostedWebView {
                    detachIfOwned(hostedWebView)
                }
                fullscreenObservation?.invalidate()
                fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) {
                    [weak self, weak webView] _, change in
                    guard change.newValue == .notInFullscreen, let webView else { return }
                    DispatchQueue.main.async {
                        self?.attach(webView)
                    }
                }
                hostedWebView = webView
            }

            guard webView.fullscreenState == .notInFullscreen else { return }
            guard shouldHost() else {
                detachIfOwned(webView)
                return
            }
            if webView.superview === self, !rehostRequested {
                refreshHostedLayout()
                return
            }
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView.frame = targetWebViewFrame()
            addSubview(webView)
            rehostRequested = false
            refreshHostedLayout()
            scheduleDeferredRefresh()
        }

        func dismantle() {
            if let hostedWebView {
                detachIfOwned(hostedWebView)
            }
            fullscreenObservation?.invalidate()
            fullscreenObservation = nil
            hostedWebView = nil
        }

        private func detachIfOwned(_ webView: WKWebView) {
            guard webView.fullscreenState == .notInFullscreen,
                  webView.superview === self else { return }
            webView.removeFromSuperview()
        }

        private func refreshHostedLayout() {
            guard let webView = hostedWebView,
                  webView.superview === self,
                  webView.fullscreenState == .notInFullscreen else { return }
            let frame = targetWebViewFrame()
            if webView.frame != frame {
                webView.frame = frame
            }
            webView.setNeedsLayout()
            webView.scrollView.setNeedsLayout()
            webView.layoutIfNeeded()
        }

        private func scheduleDeferredRefresh() {
            guard !deferredRefreshPending else { return }
            deferredRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                self?.deferredRefreshPending = false
                if let webView = self?.hostedWebView {
                    self?.attach(webView)
                }
                self?.refreshHostedLayout()
            }
        }

        private func targetWebViewFrame() -> CGRect {
            let size = bounds.size.hasPaneLayoutArea ? bounds.size : layoutSize
            return CGRect(origin: .zero, size: size.normalizedForPaneLayout)
        }
    }
}

#else

extension _Representable: NSViewRepresentable {
    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.onInteraction = onInteraction
        container.dropHandler = dropHandler
        container.shouldHost = shouldHost
        container.setLayoutRevision(layoutRevision)
        container.setLayoutSize(layoutSize)
        container.attach(webView)
        return container
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        container.onInteraction = onInteraction
        container.dropHandler = dropHandler
        container.shouldHost = shouldHost
        container.setLayoutRevision(layoutRevision)
        container.setLayoutSize(layoutSize)
        container.attach(webView)
    }

    static func dismantleNSView(_ container: ContainerView, coordinator: ()) {
        container.dismantle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ContainerView, context: Context) -> CGSize? {
        nil
    }
}

extension _Representable {
    final class ContainerView: NSView, NSGestureRecognizerDelegate {
        var onInteraction: (() -> Void)?
        var dropHandler: PaneDropHandler?
        var shouldHost: () -> Bool = { true }
        private weak var hostedWebView: WKWebView?
        private var fullscreenObservation: NSKeyValueObservation?
        private var layoutSize: CGSize = .zero
        private var layoutRevision: Int = 0
        private var rehostRequested = false
        private var deferredRefreshPending = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            let press = NSPressGestureRecognizer(target: self,
                                                 action: #selector(handleInteraction(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = 4
            press.delaysPrimaryMouseButtonEvents = false
            press.delegate = self
            addGestureRecognizer(press)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            refreshHostedLayout()
        }

        @objc private func handleInteraction(_ gr: NSGestureRecognizer) {
            if gr.state == .began { onInteraction?() }
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
            true
        }

        func setLayoutRevision(_ revision: Int) {
            guard layoutRevision != revision else { return }
            layoutRevision = revision
            rehostRequested = true
            needsLayout = true
            scheduleDeferredRefresh()
        }

        func setLayoutSize(_ size: CGSize) {
            let normalized = size.normalizedForPaneLayout
            guard layoutSize != normalized else {
                refreshHostedLayout()
                return
            }
            layoutSize = normalized
            needsLayout = true
            refreshHostedLayout()
            scheduleDeferredRefresh()
        }

        func attach(_ webView: WKWebView) {
            if hostedWebView !== webView {
                if let hostedWebView {
                    detachIfOwned(hostedWebView)
                }
                fullscreenObservation?.invalidate()
                fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) {
                    [weak self, weak webView] _, change in
                    guard change.newValue == .notInFullscreen, let webView else { return }
                    DispatchQueue.main.async {
                        self?.attach(webView)
                    }
                }
                hostedWebView = webView
            }

            guard webView.fullscreenState == .notInFullscreen else { return }
            guard shouldHost() else {
                detachIfOwned(webView)
                return
            }
            configureDropRouting(for: webView)
            if webView.superview === self, !rehostRequested {
                refreshHostedLayout()
                return
            }
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            webView.frame = targetWebViewFrame()
            addSubview(webView)
            rehostRequested = false
            refreshHostedLayout()
            scheduleDeferredRefresh()
        }

        func dismantle() {
            if let hostedWebView {
                detachIfOwned(hostedWebView)
            }
            fullscreenObservation?.invalidate()
            fullscreenObservation = nil
            hostedWebView = nil
        }

        private func detachIfOwned(_ webView: WKWebView) {
            guard webView.fullscreenState == .notInFullscreen,
                  webView.superview === self else { return }
            webView.removeFromSuperview()
        }

        private func refreshHostedLayout() {
            guard let webView = hostedWebView,
                  webView.superview === self,
                  webView.fullscreenState == .notInFullscreen else { return }
            let frame = targetWebViewFrame()
            if webView.frame != frame {
                webView.frame = frame
            }
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
        }

        private func scheduleDeferredRefresh() {
            guard !deferredRefreshPending else { return }
            deferredRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                self?.deferredRefreshPending = false
                if let webView = self?.hostedWebView {
                    self?.attach(webView)
                }
                self?.refreshHostedLayout()
            }
        }

        private func targetWebViewFrame() -> CGRect {
            let size = bounds.size.hasPaneLayoutArea ? bounds.size : layoutSize
            return CGRect(origin: .zero, size: size.normalizedForPaneLayout)
        }

        private func configureDropRouting(for webView: WKWebView) {
            guard let webView = webView as? PaneDropRoutingWebView else { return }
            webView.dropHandler = dropHandler
        }
    }
}

#endif

private extension CGSize {
    var normalizedForPaneLayout: CGSize {
        CGSize(width: width.isFinite ? max(0, width) : 0,
               height: height.isFinite ? max(0, height) : 0)
    }

    var hasPaneLayoutArea: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
