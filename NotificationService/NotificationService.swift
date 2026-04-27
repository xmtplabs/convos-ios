import ConvosCore
import ConvosCoreiOS
import Foundation
import UserNotifications

// MARK: - Global Push Handler Singleton

private let globalPushHandler: CachedPushNotificationHandler? = {
    do {
        let environment = try NotificationExtensionEnvironment.getEnvironment()
        ConvosLog.configure(environment: environment)

        Log.info("Initializing global push handler for environment: \(environment.name)")

        if !environment.isProduction {
            Log.info("Activating LibXMTP Log Writer...")
            MessagingDiagnosticsProvider.shared.activatePersistentLogWriter(
                logLevel: .debug,
                rotationSchedule: .hourly,
                maxFiles: 10,
                customLogDirectory: environment.defaultXMTPLogsDirectoryURL,
                processType: .notificationExtension
            )
        }

        let nseVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let nseBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        Log.info("Launch: version=\(nseVersion) build=\(nseBuild) commit=\(BuildInfo.commitHash) environment=\(environment.name)")

        return try NotificationExtensionEnvironment.createPushNotificationHandler(
            platformProviders: .iOSExtension
        )
    } catch {
        let errorMsg = "Failed to initialize global push handler: \(error.localizedDescription)"
        Log.error(errorMsg)
        return nil
    }
}()

// Wrapper to safely pass userInfo across isolation boundaries
// The userInfo dictionary is copied at construction time and not mutated
private struct SendableUserInfo: @unchecked Sendable {
    let value: [AnyHashable: Any]
}

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var currentProcessingTask: Task<Void, Never>?

    // Serial queue to ensure thread-safe access to contentHandler
    private let handlerQueue: DispatchQueue = DispatchQueue(label: "com.convos.nse.handler")

    // nonisolated(unsafe) is safe here because access is serialized via handlerQueue
    nonisolated(unsafe) private var contentHandler: ((UNNotificationContent) -> Void)?

    private let instanceId: Substring = UUID().uuidString.prefix(8)
    private let processId: Int32 = ProcessInfo.processInfo.processIdentifier

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let requestId = request.identifier
        self.contentHandler = contentHandler

        Log.info("[PID: \(processId)] [Instance: \(instanceId)] [Request: \(requestId)] Starting notification processing")

        guard let pushHandler = globalPushHandler else {
            Log.error("No global push handler available - suppressing notification")
            deliverNotification(UNMutableNotificationContent())
            return
        }

        currentProcessingTask?.cancel()
        let sendableUserInfo = SendableUserInfo(value: request.content.userInfo)

        currentProcessingTask = Task {
            do {
                try Task.checkCancellation()

                let payload = PushNotificationPayload(userInfo: sendableUserInfo.value)
                Log.info("Processing notification")

                let decodedContent = try await pushHandler.handlePushNotification(payload: payload)

                try Task.checkCancellation()

                if decodedContent == nil {
                    Log.info("Suppressing undecryptable notification")
                    self.deliverNotification(UNMutableNotificationContent())
                } else if decodedContent?.isDroppedMessage == true {
                    Log.info("Dropping notification as requested")
                    self.deliverNotification(UNMutableNotificationContent())
                } else if let decodedContent {
                    Log.info("Delivering processed notification")
                    let content = decodedContent.notificationContent
                    if !decodedContent.isReaction,
                       let mutableContent = content.mutableCopy() as? UNMutableNotificationContent,
                       let env = try? NotificationExtensionEnvironment.getEnvironment() {
                        let badgeCount = BadgeCounter.increment(appGroupIdentifier: env.appGroupIdentifier)
                        mutableContent.badge = NSNumber(value: badgeCount)
                        self.deliverNotification(mutableContent)
                    } else {
                        self.deliverNotification(content)
                    }
                }
            } catch is CancellationError {
                Log.info("Notification processing was cancelled")
                // serviceExtensionTimeWillExpire handles final delivery on cancellation
            } catch {
                Log.error("Error processing notification: \(error)")
                self.deliverNotification(UNMutableNotificationContent())
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        Log.warning("[Instance: \(instanceId)] Service extension time expiring")
        currentProcessingTask?.cancel()
        currentProcessingTask = nil
        if deliverNotification(UNMutableNotificationContent()) {
            Log.info("Timeout - suppressing notification with empty content")
        }
    }

    // MARK: - Helper Methods

    /// Safely delivers notification content by atomically swapping and clearing the handler
    /// Returns true if the handler was called, false if it was already consumed
    @discardableResult
    private func deliverNotification(_ content: UNNotificationContent) -> Bool {
        handlerQueue.sync {
            guard let handler = self.contentHandler else {
                return false
            }
            self.contentHandler = nil
            handler(content)
            return true
        }
    }

    deinit {
        Log.info("[Instance: \(instanceId)] NotificationService instance deallocated")
    }
}

extension DecodedNotificationContent {
    var notificationContent: UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        if let title {
            content.title = title
        }
        content.body = body
        if let conversationId {
            content.threadIdentifier = conversationId
        }
        return content
    }
}

extension PushNotificationPayload {
    var undecodedNotificationContent: UNNotificationContent {
        let content = UNMutableNotificationContent()
        if let displayTitle = displayTitle {
            content.title = displayTitle
        }
        if let displayBody = displayBody {
            content.body = displayBody
        }
        content.userInfo = userInfo
        if let conversationId = notificationData?.protocolData?.conversationId {
            content.threadIdentifier = conversationId
        }
        return content
    }
}
