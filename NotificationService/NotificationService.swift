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

        // Create the handler with iOS platform providers
        return try NotificationExtensionEnvironment.createPushNotificationHandler(
            platformProviders: .iOS
        )
    } catch {
        // Log to both console and Logger in case Logger isn't configured
        let errorMsg = "Failed to initialize global push handler: \(error.localizedDescription)"
        Log.error(errorMsg)
        return nil
    }
}()

class NotificationService: UNNotificationServiceExtension {
    // Keep track of the current processing task for cancellation
    private var currentProcessingTask: Task<Void, Never>?

    // Serial queue to ensure thread-safe access to contentHandler
    private let handlerQueue: DispatchQueue = DispatchQueue(label: "com.convos.nse.handler")

    // Store content handler for timeout scenario
    private var contentHandler: ((UNNotificationContent) -> Void)?

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

        // Create a new processing task
        currentProcessingTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // Check for early cancellation
                try Task.checkCancellation()

                let payload = PushNotificationPayload(userInfo: request.content.userInfo)
                Log.info("Processing notification")

                // Process the notification with the global handler
                let decodedContent = try await pushHandler.handlePushNotification(payload: payload)

                // Check for cancellation before delivering
                try Task.checkCancellation()

                // Determine what content to deliver
                let shouldDropMessage = decodedContent?.isDroppedMessage ?? false
                if shouldDropMessage {
                    Log.info("Dropping notification as requested")
                    deliverNotification(UNMutableNotificationContent())
                } else {
                    let notificationContent = decodedContent?.notificationContent ?? payload.undecodedNotificationContent
                    Log.info("Delivering processed notification")
                    deliverNotification(notificationContent)
                }
            } catch is CancellationError {
                Log.info("Notification processing was cancelled")
                // Don't call contentHandler here - serviceExtensionTimeWillExpire will handle it

            } catch {
                Log.error("Error processing notification: \(error)")
                // On error, suppress the notification by delivering empty content
                deliverNotification(UNMutableNotificationContent())
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
