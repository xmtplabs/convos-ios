import ConvosCore
import SwiftUI

struct UserTitleView: View {
    let name: String
    let source: MessageSource
    var body: some View {
        if !name.isEmpty {
            HStack {
                if source == .outgoing {
                    Spacer()
                }
                Text(name)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(Color.gray)
                    .truncationMode(.tail)
                if source == .incoming {
                    Spacer()
                }
            }
        } else {
            EmptyView()
        }
    }
}

#Preview {
    UserTitleView(name: "John Doe", source: .outgoing)
}

#Preview {
    UserTitleView(name: "John Doe", source: .incoming)
}
