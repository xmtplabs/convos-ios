import SwiftUI

struct PinLimitInfoView: View {
    var body: some View {
        InfoView(
            title: "Pin limit reached",
            description: "You can pin up to 9 convos. To pin this convo, unpin another one first."
        )
    }
}

#Preview {
    PinLimitInfoView()
}
