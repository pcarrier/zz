import SwiftUI

private let dividerThickness: CGFloat = 12

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
                let total = axis == .horizontal ? proxy.size.height : proxy.size.width
                let usable = max(0, total - dividerThickness)
                let firstSize = usable * ratio
                let secondSize = usable - firstSize
                Group {
                    if axis == .horizontal {
                        VStack(spacing: 0) {
                            BSPView(node: first).frame(height: firstSize)
                            SplitHandle(
                                axis: axis,
                                thickness: dividerThickness,
                                onBegin:     { store.beginRatioDrag(id) },
                                onTranslate: { t in
                                    store.updateRatioDrag(id, usable: usable, translation: t)
                                },
                                onEnd:       { store.endRatioDrag(id) }
                            )
                            BSPView(node: second).frame(height: secondSize)
                        }
                    } else {
                        HStack(spacing: 0) {
                            BSPView(node: first).frame(width: firstSize)
                            SplitHandle(
                                axis: axis,
                                thickness: dividerThickness,
                                onBegin:     { store.beginRatioDrag(id) },
                                onTranslate: { t in
                                    store.updateRatioDrag(id, usable: usable, translation: t)
                                },
                                onEnd:       { store.endRatioDrag(id) }
                            )
                            BSPView(node: second).frame(width: secondSize)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Draggable divider used by the BSP renderer and the sidebar splitter.
/// Hit area equals `thickness`; the visible line is always a 1pt hairline.
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
                    .fill(Color.gray.opacity(0.25))
                    .frame(width: axis == .vertical ? 1 : nil,
                           height: axis == .horizontal ? 1 : nil)
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
