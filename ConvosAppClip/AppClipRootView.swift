import SwiftUI

struct AppClipRootView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "balloon.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Convos")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Tap to open the full app and join the conversation.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

#Preview {
    AppClipRootView()
}
