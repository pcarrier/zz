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
                            SplitHandle(axis: axis, thickness: dividerThickness) { delta in
                                let newRatio = (firstSize + delta) / max(usable, 1)
                                store.setRatio(newRatio, for: id)
                            }
                            BSPView(node: second).frame(height: secondSize)
                        }
                    } else {
                        HStack(spacing: 0) {
                            BSPView(node: first).frame(width: firstSize)
                            SplitHandle(axis: axis, thickness: dividerThickness) { delta in
                                let newRatio = (firstSize + delta) / max(usable, 1)
                                store.setRatio(newRatio, for: id)
                            }
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
struct SplitHandle: View {
    let axis: BSPNode.Axis
    var thickness: CGFloat = 12
    let onDelta: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    init(axis: BSPNode.Axis, thickness: CGFloat = 12,
         onDelta: @escaping (CGFloat) -> Void) {
        self.axis = axis
        self.thickness = thickness
        self.onDelta = onDelta
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
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let current = axis == .horizontal
                            ? value.translation.height
                            : value.translation.width
                        let delta = current - lastTranslation
                        lastTranslation = current
                        onDelta(delta)
                    }
                    .onEnded { _ in lastTranslation = 0 }
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
