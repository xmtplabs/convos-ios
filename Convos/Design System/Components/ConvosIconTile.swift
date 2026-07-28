import SwiftUI

struct ConvosIconTile: View {
    private let image: Image
    private let foregroundColor: Color
    private let backgroundColor: Color
    private let size: CGFloat

    init(
        systemName: String,
        foregroundColor: Color = .colorTextPrimary,
        backgroundColor: Color = .colorFillMinimal,
        size: CGFloat = DesignConstants.Layout.iconTile
    ) {
        self.image = Image(systemName: systemName)
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.size = size
    }

    init(
        imageName: String,
        foregroundColor: Color = .colorTextPrimary,
        backgroundColor: Color = .colorFillMinimal,
        size: CGFloat = DesignConstants.Layout.iconTile
    ) {
        self.image = Image(imageName)
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.size = size
    }

    var body: some View {
        image
            .font(.headline)
            .foregroundStyle(foregroundColor)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(backgroundColor)
            )
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        ConvosIconTile(systemName: "qrcode")
        ConvosIconTile(
            systemName: "exclamationmark.triangle",
            foregroundColor: .colorCaution,
            backgroundColor: .colorCaution.opacity(0.08)
        )
    }
    .padding()
}
