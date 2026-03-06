import SwiftUI

struct AssistantsInfoView: View {
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            Text("About Assistants")
                .font(.title2)
                .fontWeight(.bold)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    AssistantsInfoView()
}
