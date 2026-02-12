import SwiftUI

struct MonogramView: View {
    private let initials: String

    init(text: String) {
        self.initials = text
    }

    init(name: String) {
        self.initials = Self.initials(from: name)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let fontSize = side * 0.5
            let padding = side * 0.25

            Group {
                Text(initials)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.01)
                    .lineLimit(1)
                    .foregroundColor(.colorTextPrimaryInverted)
                    .padding(padding)
            }
            .frame(width: side, height: side)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black.opacity(0.2)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .background(.colorFillTertiary)
            .clipShape(Circle())
        }
        .aspectRatio(1.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func initials(from fullName: String) -> String {
        let components = fullName.split(separator: " ")
        let initials = components.prefix(2).map { $0.first.map(String.init) ?? "" }
        return initials.joined().uppercased()
    }
}

#Preview {
    VStack {
        MonogramView(name: "Robert Adams")
            .frame(width: 24.0)
        MonogramView(name: "Robert Adams")
            .frame(width: 36.0)
        MonogramView(name: "Robert Adams")
            .frame(width: 52.0)
        MonogramView(name: "Robert Adams")
            .frame(width: 96.0)
        MonogramView(name: "Robert, John, Diana, Jessica, Tom")
            .frame(width: 96.0)
    }
}
