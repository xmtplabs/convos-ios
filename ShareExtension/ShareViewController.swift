import ConvosCore
import ConvosCoreiOS
import Foundation
import Social

/// Throwaway spike instrumentation, not the shipping share UI.
///
/// It measures whether booting the real send path inside a share extension fits
/// the 120 MB ceiling and how long boot -> send takes, logging
/// `os_proc_available_memory()` and the physical footprint at each stage to the
/// shared `convos.log`. See docs/plans/share-extension.md for the runbook.
///
/// The target conversation is read from a shared app-group default
/// (`share_spike_conversation_id`) to keep the spike free of picker UI; set it
/// from the main app or via `xcrun simctl spawn booted defaults write`.
///
/// Unbuilt until the target is wired in Xcode; the first build validates the
/// exact send call chain (`client.session.messagingService().messageWriter(...)`).
final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool {
        true
    }

    override func didSelectPost() {
        let text: String = contentText ?? ""
        Log.info("post tapped (boot) \(MemoryProbe.snapshot)")
        Task { [weak self] in
            await self?.runSpike(text: text)
            await MainActor.run { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    private func runSpike(text: String) async {
        let started: Date = Date()
        do {
            let environment = try NotificationExtensionEnvironment.getEnvironment()
            ConvosLog.configure(environment: environment)
            // libxmtp logging stays off here on purpose: enabling it crashes the
            // extension via a tracing-oslog Rust panic (see NotificationService).
            Log.info("environment=\(environment.name) \(MemoryProbe.snapshot)")

            let client = ConvosClient.client(
                environment: environment,
                platformProviders: .iOSExtension,
                coreActions: NoOpCoreActions()
            )
            let booted: Date = Date()
            Log.info("client booted in \(Self.milliseconds(from: started, to: booted))ms \(MemoryProbe.snapshot)")

            guard let conversationId = Self.spikeConversationId(for: environment) else {
                Log.error("no target conversation id; set app-group default '\(Constant.conversationIdKey)'")
                return
            }

            let writer = client.session.messagingService().messageWriter(
                for: conversationId,
                backgroundUploadManager: UnavailableBackgroundUploadManager()
            )
            try await writer.send(text: text)

            let sent: Date = Date()
            let sendMs: Int = Self.milliseconds(from: booted, to: sent)
            let totalMs: Int = Self.milliseconds(from: started, to: sent)
            Log.info("sent to \(conversationId) send=\(sendMs)ms total=\(totalMs)ms \(MemoryProbe.snapshot)")
        } catch {
            Log.error("spike failed: \(error.localizedDescription) \(MemoryProbe.snapshot)")
        }
    }

    private static func spikeConversationId(for environment: AppEnvironment) -> String? {
        let defaults = UserDefaults(suiteName: environment.appGroupIdentifier)
        guard let value = defaults?.string(forKey: Constant.conversationIdKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) * 1000)
    }

    private enum Constant {
        static let conversationIdKey: String = "share_spike_conversation_id"
    }
}
