import SwiftUI

/// A `ScrollView` that reports a definite vertical intrinsic size — the
/// content's natural height clamped to `maxHeight`. Used inside drawer-style
/// sheets where the parent applies `.fixedSize(horizontal: false, vertical: true)`
/// to compute its presentation detent: a plain `ScrollView` with
/// `.frame(maxHeight:)` reports an unbounded intrinsic size in that context,
/// which lets the parent request a sheet detent taller than the screen and
/// pushes the top of the content (e.g. the drawer's title) out of the visible
/// area.
struct BoundedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BoundedScrollContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicatorsFlash(onAppear: true)
        .scrollContentBackground(.hidden)
        .frame(height: min(max(contentHeight, 1.0), maxHeight))
        .onPreferenceChange(BoundedScrollContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct BoundedScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
