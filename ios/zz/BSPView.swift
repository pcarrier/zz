import SwiftUI

private let splitHandleHitThickness: CGFloat = 14

struct BSPView: View {
    let node: BSPNode
    var onOutsideURLBarInteraction: () -> Void = {}
    @Environment(BrowserStore.self) private var store

    var body: some View {
        switch node {
        case .leaf(let tabID):
            TileView(tabID: tabID,
                     onOutsideURLBarInteraction: onOutsideURLBarInteraction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(tabID)

        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { proxy in
                let length = axis == .horizontal ? proxy.size.height : proxy.size.width
                let firstSize = max(0, length * ratio)
                let secondSize = max(0, length - firstSize)
                ZStack(alignment: .topLeading) {
                    if axis == .horizontal {
                        BSPView(node: first,
                                onOutsideURLBarInteraction: onOutsideURLBarInteraction)
                            .frame(width: proxy.size.width, height: firstSize)
                            .position(x: proxy.size.width / 2, y: firstSize / 2)
                        BSPView(node: second,
                                onOutsideURLBarInteraction: onOutsideURLBarInteraction)
                            .frame(width: proxy.size.width, height: secondSize)
                            .position(x: proxy.size.width / 2,
                                      y: firstSize + secondSize / 2)
                        splitHandle(id: id, axis: axis, usable: length)
                            .position(x: proxy.size.width / 2, y: firstSize)
                    } else {
                        BSPView(node: first,
                                onOutsideURLBarInteraction: onOutsideURLBarInteraction)
                            .frame(width: firstSize, height: proxy.size.height)
                            .position(x: firstSize / 2, y: proxy.size.height / 2)
                        BSPView(node: second,
                                onOutsideURLBarInteraction: onOutsideURLBarInteraction)
                            .frame(width: secondSize, height: proxy.size.height)
                            .position(x: firstSize + secondSize / 2,
                                      y: proxy.size.height / 2)
                        splitHandle(id: id, axis: axis, usable: length)
                            .position(x: firstSize, y: proxy.size.height / 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if store.selectedGroupID == id {
                        SelectedGroupOutline()
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func splitHandle(id: UUID, axis: BSPNode.Axis, usable: CGFloat) -> some View {
        SplitHandle(
            axis: axis,
            thickness: splitHandleHitThickness,
            onSelect:    {
                onOutsideURLBarInteraction()
                store.selectGroup(id)
            },
            onBegin:     {
                onOutsideURLBarInteraction()
                store.beginRatioDrag(id)
            },
            onTranslate: { t in store.updateRatioDrag(id, usable: usable, translation: t) },
            onEnd:       { store.endRatioDrag(id) }
        )
    }
}

private struct SelectedGroupOutline: View {
    var body: some View {
        Rectangle()
            .stroke(Color.textSelection,
                    lineWidth: PaneSelectionVisual.strokeWidth)
            .padding(1)
    }
}

struct SplitHandle: View {
    let axis: BSPNode.Axis
    var thickness: CGFloat = 12
    var onSelect: () -> Void = {}
    var onBegin: () -> Void = {}
    let onTranslate: (CGFloat) -> Void
    var onEnd: () -> Void = {}

    @State private var lastEmitTime: CFTimeInterval = 0
    @State private var didBegin = false
    @GestureState private var gestureActive = false

    var body: some View {
        Color.clear
            .frame(width: axis == .vertical ? thickness : nil,
                   height: axis == .horizontal ? thickness : nil)
            .overlay {
                Rectangle()
                    .fill(.separator)
                    .frame(width: axis == .vertical ? 0.5 : nil,
                           height: axis == .horizontal ? 0.5 : nil)
            }
            .contentShape(.rect)
            .simultaneousGesture(
                TapGesture().onEnded(onSelect)
            )
            .gesture(
                // Global coordinates avoid feedback as the divider moves.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($gestureActive) { _, state, _ in state = true }
                    .onChanged { value in
                        // Throttle WKWebView relayout during drag.
                        let now = CACurrentMediaTime()
                        if now - lastEmitTime < 1.0 / 60.0 { return }
                        lastEmitTime = now
                        // Capture the baseline exactly once per gesture. onChanged
                        // fires every frame with a cumulative translation, so calling
                        // onBegin() each frame would re-capture an already-moved ratio
                        // and double-count the translation (divider runaway).
                        if !didBegin {
                            didBegin = true
                            onBegin()
                        }
                        let cumulative = axis == .horizontal
                            ? value.translation.height
                            : value.translation.width
                        onTranslate(cumulative)
                    }
                    .onEnded { value in
                        lastEmitTime = 0
                        let cumulative = axis == .horizontal
                            ? value.translation.height
                            : value.translation.width
                        onTranslate(cumulative)
                        onEnd()
                        didBegin = false
                    }
            )
            .onChange(of: gestureActive) { _, active in
                // @GestureState resets to false on end OR cancellation, so this
                // clears didBegin even when .onEnded is dropped (gesture preempted),
                // ensuring the next gesture re-captures a fresh baseline.
                if !active { didBegin = false }
            }
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
