import SwiftUI

private let splitHandleHitThickness: CGFloat = 14

struct BSPView: View {
    let node: BSPNode
    @Environment(BrowserStore.self) private var store

    var body: some View {
        switch node {
        case .leaf(let tabID):
            TileView(tabID: tabID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(tabID)

        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { proxy in
                let length = axis == .horizontal ? proxy.size.height : proxy.size.width
                let firstSize = max(0, length * ratio)
                let secondSize = max(0, length - firstSize)
                ZStack(alignment: .topLeading) {
                    if axis == .horizontal {
                        BSPView(node: first)
                            .frame(width: proxy.size.width, height: firstSize)
                            .position(x: proxy.size.width / 2, y: firstSize / 2)
                        BSPView(node: second)
                            .frame(width: proxy.size.width, height: secondSize)
                            .position(x: proxy.size.width / 2,
                                      y: firstSize + secondSize / 2)
                        splitHandle(id: id, axis: axis, usable: length)
                            .position(x: proxy.size.width / 2, y: firstSize)
                    } else {
                        BSPView(node: first)
                            .frame(width: firstSize, height: proxy.size.height)
                            .position(x: firstSize / 2, y: proxy.size.height / 2)
                        BSPView(node: second)
                            .frame(width: secondSize, height: proxy.size.height)
                            .position(x: firstSize + secondSize / 2,
                                      y: proxy.size.height / 2)
                        splitHandle(id: id, axis: axis, usable: length)
                            .position(x: firstSize, y: proxy.size.height / 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func splitHandle(id: UUID, axis: BSPNode.Axis, usable: CGFloat) -> some View {
        SplitHandle(
            axis: axis,
            thickness: splitHandleHitThickness,
            onBegin:     { store.beginRatioDrag(id) },
            onTranslate: { t in store.updateRatioDrag(id, usable: usable, translation: t) },
            onEnd:       { store.endRatioDrag(id) }
        )
    }
}

/// Draggable divider used by the BSP renderer and the sidebar splitter.
/// Hit area equals `thickness`; the visible line is only a quiet hairline.
///
/// Callers receive `cumulative` translation from the gesture's start (not deltas)
/// so they can compute the new size from a stable starting reference, which
/// avoids jumps if SwiftUI rebuilds the handle mid-drag (any internal
/// `@State` "lastTranslation" can be lost across tree rebuilds).
struct SplitHandle: View {
    let axis: BSPNode.Axis
    var thickness: CGFloat = 12
    var onBegin: () -> Void = {}
    let onTranslate: (CGFloat) -> Void
    var onEnd: () -> Void = {}

    @State private var lastEmitTime: CFTimeInterval = 0

    init(axis: BSPNode.Axis,
         thickness: CGFloat = 12,
         onBegin: @escaping () -> Void = {},
         onTranslate: @escaping (CGFloat) -> Void,
         onEnd: @escaping () -> Void = {}) {
        self.axis = axis
        self.thickness = thickness
        self.onBegin = onBegin
        self.onTranslate = onTranslate
        self.onEnd = onEnd
    }

    var body: some View {
        Color.clear
            .frame(width: axis == .vertical ? thickness : nil,
                   height: axis == .horizontal ? thickness : nil)
            .overlay {
                Rectangle()
                    .fill(.separator.opacity(0.22))
                    .frame(width: axis == .vertical ? 0.5 : nil,
                           height: axis == .horizontal ? 0.5 : nil)
            }
            .contentShape(.rect)
            .gesture(
                // `.global` so translation tracks the finger relative to the
                // screen — not to the SplitHandle's local frame, which moves
                // with the divider mid-drag and otherwise halves the reported
                // distance.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        // Throttle: WebContent can't keep up with 120 Hz drag
                        // events when WKWebViews need to relayout. Cap at ~60 Hz.
                        let now = CACurrentMediaTime()
                        if now - lastEmitTime < 1.0 / 60.0 { return }
                        lastEmitTime = now
                        // `onBegin` is idempotent on the receiving side, so
                        // calling it on every event is safe and removes the
                        // need for fragile per-handle `@State`.
                        onBegin()
                        let cumulative = axis == .horizontal
                            ? value.translation.height
                            : value.translation.width
                        onTranslate(cumulative)
                    }
                    .onEnded { value in
                        // Always deliver the final position regardless of throttle.
                        lastEmitTime = 0
                        let cumulative = axis == .horizontal
                            ? value.translation.height
                            : value.translation.width
                        onTranslate(cumulative)
                        onEnd()
                    }
            )
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    if axis == .horizontal {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.resizeLeftRight.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            #endif
    }
}
