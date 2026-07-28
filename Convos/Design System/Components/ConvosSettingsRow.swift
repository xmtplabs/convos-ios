import SwiftUI

struct ConvosSettingsRow<Accessory: View>: View {
    let iconSystemName: String
    let title: String
    let subtitle: String?
    private let accessory: Accessory

    init(
        iconSystemName: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.iconSystemName = iconSystemName
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ConvosIconTile(systemName: iconSystemName)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .convosTextStyle(.body)

                if let subtitle {
                    Text(subtitle)
                        .convosTextStyle(.detail)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: DesignConstants.Spacing.step2x)
            accessory
        }
        .frame(minHeight: DesignConstants.Layout.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    @Previewable @State var isOn: Bool = true
    VStack {
        ConvosSettingsRow(
            iconSystemName: "eye",
            title: "Read receipts",
            subtitle: "Let others know when you have read their messages"
        ) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }

        ConvosSettingsRow(
            iconSystemName: "person.2",
            title: "Members"
        ) {
            Image(systemName: "chevron.right")
                .foregroundStyle(.colorTextTertiary)
        }
    }
    .padding()
}
