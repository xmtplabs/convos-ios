import ConvosCore
import ConvosCoreiOS
import Foundation
import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Throwaway spike compose UI for the share extension. A custom UIViewController
/// (not SLComposeServiceViewController) so we control the chrome: a real "Send"
/// button, the target conversation in the header, and the same send path as the
/// app (attachment first, then text).
final class ShareViewController: UIViewController {
    private let model: ShareComposeModel = ShareComposeModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let composeView = ShareComposeView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onSend: { [weak self] in self?.complete() }
        )
        let host = UIHostingController(rootView: composeView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        model.start(extensionContext: extensionContext)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: NSUserCancelledError))
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

@MainActor
@Observable
final class ShareComposeModel {
    var targetTitle: String = "Convo"
    var messageText: String = ""
    var sharedImage: UIImage?
    var isReady: Bool = false
    var isSending: Bool = false

    private var client: ConvosClient?
    private var targetConversationId: String?

    var canSend: Bool {
        let hasText: Bool = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isReady && !isSending && (sharedImage != nil || hasText)
    }

    func start(extensionContext: NSExtensionContext?) {
        Task { await prepare(extensionContext: extensionContext) }
    }

    private func prepare(extensionContext: NSExtensionContext?) async {
        do {
            let environment = try NotificationExtensionEnvironment.getEnvironment()
            ConvosLog.configure(environment: environment)
            ConfigManager.configure(overrides: .empty)
            DeviceInfo.configure(IOSDeviceInfo())
            ImageCompression.configure(IOSImageCompression())
            PushNotificationRegistrar.configure(IOSPushNotificationRegistrar())
            RichLinkMetadata.configure(IOSRichLinkMetadataProvider())
            if let firebaseConfigURL = ConfigManager.shared.currentEnvironment.firebaseConfigURL {
                FirebaseHelperCore.configure(
                    with: firebaseConfigURL,
                    debugToken: Secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN,
                    forceDebugProvider: true
                )
            }
            let client = ConvosClient.client(
                environment: environment,
                platformProviders: .iOSExtension,
                coreActions: NoOpCoreActions()
            )
            self.client = client

            let conversations = (try? client.session.conversationsRepository(for: [.allowed]).fetchAll()) ?? []
            let intent = extensionContext?.intent as? INSendMessageIntent
            let target = conversations.first { $0.id == intent?.conversationIdentifier } ?? conversations.first
            targetConversationId = target?.id
            // The donated intent carries the conversation's display name
            // (Conversation.title lives in the app target, not here).
            targetTitle = intent?.speakableGroupName?.spokenPhrase ?? target?.name ?? "Convo"

            sharedImage = await Self.loadSharedImage(extensionContext: extensionContext)
            isReady = targetConversationId != nil
        } catch {
            Log.error("prepare failed: \(error.localizedDescription)")
        }
    }

    func send() async {
        guard let client, let targetConversationId else {
            return
        }
        isSending = true
        let text: String = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let messagingService = client.session.messagingService()
        do {
            // Attachments first, then text - matches the in-app send order.
            if let image = sharedImage {
                let imageWriter = messagingService.messageWriter(
                    for: targetConversationId,
                    backgroundUploadManager: ForegroundUploadManager()
                )
                try await imageWriter.send(image: image)
            }
            if !text.isEmpty {
                let textWriter = messagingService.messageWriter(
                    for: targetConversationId,
                    backgroundUploadManager: UnavailableBackgroundUploadManager()
                )
                try await textWriter.send(text: text)
            }
            Log.info("sent to \(targetConversationId) image=\(sharedImage != nil) text=\(!text.isEmpty)")
        } catch {
            Log.error("send failed: \(error.localizedDescription)")
        }
        isSending = false
    }

    private static func loadSharedImage(extensionContext: NSExtensionContext?) async -> UIImage? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let image = await loadImage(from: provider) {
                    return image
                }
            }
        }
        return nil
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                let image: UIImage?
                switch item {
                case let url as URL:
                    image = (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
                case let data as Data:
                    image = UIImage(data: data)
                case let provided as UIImage:
                    image = provided
                default:
                    image = nil
                }
                continuation.resume(returning: image)
            }
        }
    }
}

struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel
    let onCancel: () -> Void
    let onSend: () -> Void

    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            composeArea
            Spacer(minLength: 0)
        }
        .onAppear { messageFocused = true }
    }

    private var navigationBar: some View {
        HStack {
            Button("Cancel", action: onCancel)
            Spacer()
            VStack(spacing: 1) {
                Text("To").font(.caption2).foregroundStyle(.secondary)
                Text(model.targetTitle).font(.headline).lineLimit(1)
            }
            Spacer()
            sendButton
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var sendButton: some View {
        Button(action: handleSend) {
            if model.isSending {
                ProgressView()
            } else {
                Text("Send").fontWeight(.semibold)
            }
        }
        .disabled(!model.canSend)
    }

    private var composeArea: some View {
        HStack(alignment: .top, spacing: 12) {
            TextField("Message \(model.targetTitle)", text: $model.messageText, axis: .vertical)
                .focused($messageFocused)
                .lineLimit(3...10)
            if let image = model.sharedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding()
    }

    private func handleSend() {
        Task {
            await model.send()
            onSend()
        }
    }
}
