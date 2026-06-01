import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum PaneDropPayload {
    case url(String)
    case parkedTab(UUID)
}

struct PaneDropHandler {
    var update: (CGPoint, CGSize) -> Void
    var perform: (PaneDropPayload, CGPoint, CGSize) -> Void
    var end: () -> Void
}

struct HostedWebView: View {
    let webView: WKWebView
    var onInteraction: (() -> Void)? = nil
    var dropHandler: PaneDropHandler? = nil
    var shouldHost: () -> Bool = { true }
    var reservesTopSafeArea: Bool = true
    var layoutRevision: Int = 0

    var body: some View {
        GeometryReader { proxy in
            _Representable(
                webView: webView,
                onInteraction: onInteraction,
                dropHandler: dropHandler,
                shouldHost: shouldHost,
                reservesTopSafeArea: reservesTopSafeArea,
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
    let reservesTopSafeArea: Bool
    let layoutRevision: Int
    let layoutSize: CGSize
}

#if canImport(UIKit)

extension _Representable: UIViewRepresentable {
    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.onInteraction = onInteraction
        container.shouldHost = shouldHost
        container.reservesTopSafeArea = reservesTopSafeArea
        container.setLayoutRevision(layoutRevision)
        container.setLayoutSize(layoutSize)
        container.attach(webView)
        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        container.onInteraction = onInteraction
        container.shouldHost = shouldHost
        container.reservesTopSafeArea = reservesTopSafeArea
        container.setLayoutRevision(layoutRevision)
        container.setLayoutSize(layoutSize)
        container.attach(webView)
    }

    static func dismantleUIView(_ container: ContainerView, coordinator: ()) {
        container.dismantle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContainerView, context: Context) -> CGSize? {
        nil
    }
}

extension _Representable {
    /// Reparents the externally owned `WKWebView` without tearing it down.
    final class ContainerView: UIView {
        var onInteraction: (() -> Void)?
        var shouldHost: () -> Bool = { true }
        var reservesTopSafeArea: Bool = true {
            didSet {
                guard oldValue != reservesTopSafeArea else { return }
                setNeedsLayout()
                scheduleDeferredRefresh()
            }
        }

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

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            refreshHostedLayout()
        }

        /// Detects focus without installing a competing gesture recognizer.
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
            if hostedWebView === webView {
                fullscreenObservation?.invalidate()
                fullscreenObservation = nil
                hostedWebView = nil
            }
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
            updateContentInsets(for: webView)
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

        private func updateContentInsets(for webView: WKWebView) {
            let scrollView = webView.scrollView
            let targetTopInset = reservesTopSafeArea ? reservedTopPageInset : .zero
            let previousTopInset = scrollView.contentInset.top
            guard previousTopInset != targetTopInset else { return }

            let wasPinnedToTop = scrollView.contentOffset.y <= -previousTopInset

            var contentInset = scrollView.contentInset
            contentInset.top = targetTopInset
            scrollView.contentInset = contentInset

            var indicatorInsets = scrollView.verticalScrollIndicatorInsets
            indicatorInsets.top = targetTopInset
            scrollView.verticalScrollIndicatorInsets = indicatorInsets

            if wasPinnedToTop {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: -targetTopInset),
                    animated: false
                )
            }
        }

        private var reservedTopPageInset: CGFloat {
            guard safeAreaInsets.top > .zero else { return .zero }
            guard let overlap = topSystemOverlayOverlap else { return safeAreaInsets.top }
            return safeAreaInsets.top > overlap ? overlap : .zero
        }

        private var topSystemOverlayOverlap: CGFloat? {
            guard let window,
                  let statusFrame = window.windowScene?.statusBarManager?.statusBarFrame,
                  !statusFrame.isEmpty else { return nil }

            let statusFrameInWindow = window.screen.coordinateSpace.convert(
                statusFrame,
                to: window.coordinateSpace
            )
            let boundsInWindow = convert(bounds, to: window)
            let overlap = boundsInWindow.intersection(statusFrameInWindow).height
            return overlap > .zero ? min(safeAreaInsets.top, overlap) : .zero
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
            if hostedWebView === webView {
                fullscreenObservation?.invalidate()
                fullscreenObservation = nil
                hostedWebView = nil
                // Break the retain cycle: the drop handler closures strongly
                // capture the BrowserStore, so clear it when we relinquish the
                // web view. attach() re-establishes it via configureDropRouting.
                (webView as? PaneDropRoutingWebView)?.dropHandler = nil
            }
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
