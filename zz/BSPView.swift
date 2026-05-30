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
            onSelect:    { store.selectGroup(id) },
            onBegin:     { store.beginRatioDrag(id) },
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

    init(axis: BSPNode.Axis,
         thickness: CGFloat = 12,
         onSelect: @escaping () -> Void = {},
         onBegin: @escaping () -> Void = {},
         onTranslate: @escaping (CGFloat) -> Void,
         onEnd: @escaping () -> Void = {}) {
        self.axis = axis
        self.thickness = thickness
        self.onSelect = onSelect
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
                    .onChanged { value in
                        // Throttle WKWebView relayout during drag.
                        let now = CACurrentMediaTime()
                        if now - lastEmitTime < 1.0 / 60.0 { return }
                        lastEmitTime = now
                        onBegin()
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
