import ConvosConnections
import SwiftUI

@main
struct ConvosConnectionsExampleApp: App {
    @State private var model: ExampleModel = ExampleModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RootConnectionsView(model: model)
                    .navigationDestination(for: MockConversation.self) { conversation in
                        ConnectionFeedView(conversation: conversation, model: model)
                    }
            }
            .task { await model.refresh() }
            .sheet(
                isPresented: Binding(
                    get: { model.confirmationHandler.pendingRequest != nil },
                    set: { newValue in
                        if !newValue, model.confirmationHandler.pendingRequest != nil {
                            model.confirmationHandler.resolve(.denied)
                        }
                    }
                )
            ) {
                if let request = model.confirmationHandler.pendingRequest {
                    ConfirmationSheet(request: request, handler: model.confirmationHandler)
                }
            }
        }
    }
}
