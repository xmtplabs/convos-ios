import SwiftUI

enum ComponentCategory: String, CaseIterable, Identifiable {
    case buttons = "Buttons"
    case textInputs = "Text Inputs"
    case avatars = "Avatars"
    case containers = "Containers"
    case feedback = "Feedback"
    case animations = "Animations"
    case views = "Views"
    case designTokens = "Design Tokens"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .buttons: return "rectangle.and.hand.point.up.left.filled"
        case .textInputs: return "character.cursor.ibeam"
        case .avatars: return "person.crop.circle"
        case .containers: return "square.stack"
        case .feedback: return "exclamationmark.bubble"
        case .animations: return "sparkles"
        case .views: return "rectangle.on.rectangle"
        case .designTokens: return "paintpalette"
        }
    }

    var description: String {
        switch self {
        case .buttons:
            return "Button styles including outline, rounded, text, and hold-to-confirm variants"
        case .textInputs:
            return "Text fields, text editors, and specialized input components"
        case .avatars:
            return "Profile images, monograms, and conversation avatars"
        case .containers:
            return "Layout containers, info views, and compositional components"
        case .feedback:
            return "Error views, loading indicators, and user feedback components"
        case .animations:
            return "Draggable views, pulsing indicators, and animated effects"
        case .views:
            return "Complete app screens and reusable view compositions"
        case .designTokens:
            return "Colors, spacing, corner radii, and typography"
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .buttons:
            ButtonsGuidebookView()
        case .textInputs:
            TextInputsGuidebookView()
        case .avatars:
            AvatarsGuidebookView()
        case .containers:
            ContainersGuidebookView()
        case .feedback:
            FeedbackGuidebookView()
        case .animations:
            AnimationsGuidebookView()
        case .views:
            ViewsGuidebookView()
        case .designTokens:
            DesignTokensGuidebookView()
        }
    }
}
