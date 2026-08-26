import SwiftUI
import UIKit

/// The Space stylesheet's tile values, restated for the native tiles.
///
/// These mirror `assets/space.css` in the deployed Space so a reader who has
/// seen the web page sees the same tile here. They are duplicated rather than
/// derived because the stylesheet is CSS in another repository; a screenshot
/// test over a fixture Space is what keeps the two honest.
enum SpaceTileStyle {
    /// `--radius-tile`
    static let radius: CGFloat = 32.0
    /// `--space-lg`, the grid gutter and the header's side padding.
    static let large: CGFloat = 24.0
    /// `--space-sm`
    static let small: CGFloat = 16.0
    /// `--space-xs`
    static let extraSmall: CGFloat = 12.0
    /// Row and header height.
    static let rowHeight: CGFloat = 41.0
    /// Avatar edge in the members grid.
    static let avatarSize: CGFloat = 56.0

    /// `--color-fill-minimal`, the tile's own ground.
    static var fillMinimal: Color { Color(light: 0xFA_FA_FA, dark: 0x2C_2C_2E) }
    /// `--color-fill-tertiary`, an initial avatar's ground.
    static var fillTertiary: Color { Color(light: 0xB2_B2_B2, dark: 0x63_63_66) }
    /// `--color-fill-primary`, the neutral header and the invite cell.
    static var fillPrimary: Color { Color(light: 0x00_00_00, dark: 0x00_00_00) }
    /// `--color-notes`, the notes header.
    static var notes: Color { Color(light: 0xFF_44_30, dark: 0xFF_45_3A) }
    /// `--color-border-subtle`, the rule between rows.
    static var borderSubtle: Color { Color(light: 0xEB_EB_EB, dark: 0x38_38_3A) }
    /// `--color-text-tertiary`, the hint under a short tile.
    static var textTertiary: Color { Color(light: 0xB2_B2_B2, dark: 0x8E_8E_93) }
    /// `--color-on-accent`
    static var onAccent: Color { .white }
    /// `--color-bg-surface`, the hairline that separates a tile from the page.
    static var surface: Color { Color(light: 0xFF_FF_FF, dark: 0x1C_1C_1E) }

    /// `.space-tile-header-name` and `.space-tile-row`
    static let bodyFont: Font = .system(size: 13, weight: .regular)
    static let headerNameFont: Font = .system(size: 13, weight: .medium)
    /// `.space-tile-hint`
    static let hintFont: Font = .system(size: 12)
}

private extension Color {
    /// One token with its light and dark hex, resolved by the current trait.
    init(light: UInt32, dark: UInt32) {
        self.init(
            uiColor: UIColor { traits in
                UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
