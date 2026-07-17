#if canImport(UIKit)
import SwiftUI
import UIKit

public extension Font {
    static let convosTitle: Font = .system(size: 40.0, weight: .bold)
    static let convosTitleTracking: CGFloat = -1.0
}

public enum DesignConstants {
    public enum ImageSizes {
        public static let extraSmallAvatar: CGFloat = 16.0
        public static let smallAvatar: CGFloat = 24.0
        public static let mediumAvatar: CGFloat = 40.0
        public static let largeAvatar: CGFloat = 80.0
    }

    public enum Spacing {
        public static let small: CGFloat = 16.0
        public static let medium: CGFloat = 24.0

        public static let stepHalf: CGFloat = 2.0
        public static let stepX: CGFloat = 4.0
        public static let step2x: CGFloat = 8.0
        public static let step3x: CGFloat = 12.0
        public static let step3HalfX: CGFloat = 14.0
        public static let step4x: CGFloat = 16.0
        public static let step5x: CGFloat = 20.0
        public static let step6x: CGFloat = 24.0
        public static let step8x: CGFloat = 32.0
        public static let step9x: CGFloat = 36.0
        public static let step10x: CGFloat = 40.0
        public static let step11x: CGFloat = 44.0
        public static let step12x: CGFloat = 48.0
        public static let step16x: CGFloat = 64.0
    }

    public enum CornerRadius {
        public static let extraLarge: CGFloat = 56.0
        public static let large: CGFloat = 40.0
        public static let mediumLargest: CGFloat = 34.0
        public static let mediumLarger: CGFloat = 32.0 // lol
        public static let mediumLarge: CGFloat = 24.0
        public static let photo: CGFloat = 18.0
        public static let medium: CGFloat = 16.0
        public static let regular: CGFloat = 12.0
        public static let small: CGFloat = 8.0
    }

    public enum Colors {
        public static let light: Color = .white
        /// Subtle neutral fill (Figma `color/fill/subtle`): #F5F5F5 in light,
        /// #333333 in dark. Surfaces the existing `colorFillSubtle` asset under
        /// `DesignConstants` so the QR tile and share-link button can reference
        /// the token by name rather than the raw asset symbol.
        public static let fillSubtle: Color = .colorFillSubtle
        /// Primary/secondary text tokens, exposed for extension targets that
        /// consume the package but can't see its internal asset accessors.
        public static let textPrimary: Color = .colorTextPrimary
        public static let textSecondary: Color = .colorTextSecondary
        /// Raised-surface backdrop (Figma `color/background/raised-secondary`),
        /// the color the agent builder floats over before Make reveals the
        /// conversation beneath it.
        public static let backgroundRaisedSecondary: Color = .colorBackgroundRaisedSecondary
    }

    public enum Fonts {
        public static let standard: Font = .system(size: 24.0)
        public static let medium: Font = .system(size: 16.0)
        public static let small: Font = .system(size: 12.0)
        public static let buttonText: Font = .system(size: 14.0)
        public static let caption3: Font = .system(size: 8.0)
    }
}
#endif
