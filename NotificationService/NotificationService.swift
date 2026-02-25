import ConvosCore
import ConvosCoreiOS
import Foundation
import UserNotifications
import XMTPiOS

// MARK: - Global Push Handler Singleton
// Shared across all NSE process instances for efficiency and thread safety
// The actor ensures thread-safe access from multiple notification deliveries
private let globalPushHandler: CachedPushNotificationHandler? = {
    do {
        // Configure logging first (automatically disabled in production)
        let environment = try NotificationExtensionEnvironment.getEnvironment()
        ConvosLog.configure(environment: environment)

        Log.info("Initializing global push handler for environment: \(environment.name)")

        // only enable LibXMTP logging in non-production environments
        if !environment.isProduction {
            Log.info("Activating LibXMTP Log Writer...")
            Client.activatePersistentLibXMTPLogWriter(
                logLevel: .debug,
                rotationSchedule: .hourly,
                maxFiles: 10,
                customLogDirectory: environment.defaultXMTPLogsDirectoryURL,
                processType: .notificationExtension
            )
        }

        // Create the handler with iOS extension platform providers
        // (uses mock providers since extensions don't need full app functionality)
        return try NotificationExtensionEnvironment.createPushNotificationHandler(
            platformProviders: .iOSExtension
        )
    } catch {
        // Log to both console and Logger in case Logger isn't configured
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
    // Keep track of the current processing task for cancellation
    private var currentProcessingTask: Task<Void, Never>?

    // Serial queue to ensure thread-safe access to contentHandler
    private let handlerQueue: DispatchQueue = DispatchQueue(label: "com.convos.nse.handler")

    // Store content handler for timeout scenario
    // nonisolated(unsafe) is appropriate here because access is serialized via handlerQueue
    nonisolated(unsafe) private var contentHandler: ((UNNotificationContent) -> Void)?

    // Track lifecycle for debugging
    private let instanceId: Substring = UUID().uuidString.prefix(8)
    private let processId: Int32 = ProcessInfo.processInfo.processIdentifier

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let requestId = request.identifier

        // Store content handler for timeout scenario
        self.contentHandler = contentHandler

        Log.info("[PID: \(processId)] [Instance: \(instanceId)] [Request: \(requestId)] Starting notification processing")

        guard let pushHandler = globalPushHandler else {
            Log.error("No global push handler available - suppressing notification")
            // Deliver empty notification to suppress display
            deliverNotification(UNMutableNotificationContent())
            return
        }

        // Cancel any previous task if still running (shouldn't happen but be safe)
        currentProcessingTask?.cancel()

        // Wrap userInfo for safe transfer across isolation boundaries
        let sendableUserInfo = SendableUserInfo(value: request.content.userInfo)

        // Create a new processing task
        currentProcessingTask = Task {
            do {
                // Check for early cancellation
                try Task.checkCancellation()

                let payload = PushNotificationPayload(userInfo: sendableUserInfo.value)
                Log.info("Processing notification")

                // Process the notification with the global handler
                let decodedContent = try await pushHandler.handlePushNotification(payload: payload)

                // Check for cancellation before delivering
                try Task.checkCancellation()

                // Determine what content to deliver
                if decodedContent == nil {
                    Log.info("Suppressing undecryptable notification")
                    self.deliverNotification(UNMutableNotificationContent())
                } else if decodedContent?.isDroppedMessage == true {
                    Log.info("Dropping notification as requested")
                    self.deliverNotification(UNMutableNotificationContent())
                } else if let decodedContent {
                    Log.info("Delivering processed notification")
                    self.deliverNotification(decodedContent.notificationContent)
                }
            } catch is CancellationError {
                Log.info("Notification processing was cancelled")
                // Don't call contentHandler here - serviceExtensionTimeWillExpire will handle it

            } catch {
                Log.error("Error processing notification: \(error)")
                // On error, suppress the notification by delivering empty content
                self.deliverNotification(UNMutableNotificationContent())
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system
        Log.warning("[Instance: \(instanceId)] Service extension time expiring")

        // Cancel any ongoing processing
        currentProcessingTask?.cancel()
        currentProcessingTask = nil

        // Always deliver empty notification on timeout to suppress display
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

// What we show when the notification fails to decode/process
extension PushNotificationPayload {
    var undecodedNotificationContent: UNNotificationContent {
        let content = UNMutableNotificationContent()

        // Use the basic display logic first
        if let displayTitle = displayTitle {
            content.title = displayTitle
        }

        if let displayBody = displayBody {
            content.body = displayBody
        }

        content.userInfo = userInfo

        // Set thread identifier for conversation grouping
        if let conversationId = notificationData?.protocolData?.conversationId {
            content.threadIdentifier = conversationId
        }

        return content
    }
}
