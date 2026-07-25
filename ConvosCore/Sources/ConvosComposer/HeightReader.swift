#if canImport(UIKit)
import SwiftUI

public struct HeightPreferenceKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct HeightReader: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
        }
    }
}

public extension View {
    func readHeight(onChange: @escaping (CGFloat) -> Void) -> some View {
        self
            .background(HeightReader())
            .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }
}
#endif
