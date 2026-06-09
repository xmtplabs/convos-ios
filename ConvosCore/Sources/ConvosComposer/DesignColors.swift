#if canImport(UIKit)
import SwiftUI

// Color accessors for the composer's design-system colors, resolved from
// this package's own asset catalog (bundle: .module). Mirrors the app's
// generated symbols so moved composer code keeps compiling unchanged.
// swiftlint:disable identifier_name
extension ShapeStyle where Self == Color {
    static var backgroundSurface: Color { Color("backgroundSurface", bundle: .module) }
    static var colorAI: Color { Color("colorAI", bundle: .module) }
    static var colorBackgroundInverted: Color { Color("colorBackgroundInverted", bundle: .module) }
    static var colorBackgroundMedia: Color { Color("colorBackgroundMedia", bundle: .module) }
    static var colorBackgroundPic: Color { Color("colorBackgroundPic", bundle: .module) }
    static var colorBackgroundRaised: Color { Color("colorBackgroundRaised", bundle: .module) }
    static var colorBackgroundRaisedSecondary: Color { Color("colorBackgroundRaisedSecondary", bundle: .module) }
    static var colorBackgroundSubtle: Color { Color("colorBackgroundSubtle", bundle: .module) }
    static var colorBackgroundSurfaceless: Color { Color("colorBackgroundSurfaceless", bundle: .module) }
    static var colorBlue: Color { Color("colorBlue", bundle: .module) }
    static var colorBorderEdge: Color { Color("colorBorderEdge", bundle: .module) }
    static var colorBorderSubtle: Color { Color("colorBorderSubtle", bundle: .module) }
    static var colorBorderSubtle2: Color { Color("colorBorderSubtle2", bundle: .module) }
    static var colorBubble: Color { Color("colorBubble", bundle: .module) }
    static var colorBubbleIncoming: Color { Color("colorBubbleIncoming", bundle: .module) }
    static var colorCaution: Color { Color("colorCaution", bundle: .module) }
    static var colorDarkAlpha15: Color { Color("colorDarkAlpha15", bundle: .module) }
    static var colorEmail: Color { Color("colorEmail", bundle: .module) }
    static var colorFillInvertedMinimal: Color { Color("colorFillInvertedMinimal", bundle: .module) }
    static var colorFillInvertedSubtle: Color { Color("colorFillInvertedSubtle", bundle: .module) }
    static var colorFillMinimal: Color { Color("colorFillMinimal", bundle: .module) }
    static var colorFillPrimary: Color { Color("colorFillPrimary", bundle: .module) }
    static var colorFillReaxFace: Color { Color("colorFillReaxFace", bundle: .module) }
    static var colorFillReaxHeart: Color { Color("colorFillReaxHeart", bundle: .module) }
    static var colorFillSecondary: Color { Color("colorFillSecondary", bundle: .module) }
    static var colorFillSubtle: Color { Color("colorFillSubtle", bundle: .module) }
    static var colorFillTertiary: Color { Color("colorFillTertiary", bundle: .module) }
    static var colorGreen: Color { Color("colorGreen", bundle: .module) }
    static var colorInternet: Color { Color("colorInternet", bundle: .module) }
    static var colorLava: Color { Color("colorLava", bundle: .module) }
    static var colorLinkBackground: Color { Color("colorLinkBackground", bundle: .module) }
    static var colorOrange: Color { Color("colorOrange", bundle: .module) }
    static var colorOrganize: Color { Color("colorOrganize", bundle: .module) }
    static var colorPhotos: Color { Color("colorPhotos", bundle: .module) }
    static var colorPurpleMute: Color { Color("colorPurpleMute", bundle: .module) }
    static var colorRed: Color { Color("colorRed", bundle: .module) }
    static var colorReminders: Color { Color("colorReminders", bundle: .module) }
    static var colorStandard: Color { Color("colorStandard", bundle: .module) }
    static var colorTextDarkBg: Color { Color("colorTextDarkBg", bundle: .module) }
    static var colorTextInactive: Color { Color("colorTextInactive", bundle: .module) }
    static var colorTexting: Color { Color("colorTexting", bundle: .module) }
    static var colorTextPrimary: Color { Color("colorTextPrimary", bundle: .module) }
    static var colorTextPrimaryInverted: Color { Color("colorTextPrimaryInverted", bundle: .module) }
    static var colorTextSecondary: Color { Color("colorTextSecondary", bundle: .module) }
    static var colorTextTertiary: Color { Color("colorTextTertiary", bundle: .module) }
    static var colorVibrantQuaternary: Color { Color("colorVibrantQuaternary", bundle: .module) }
}
// swiftlint:enable identifier_name
#endif
