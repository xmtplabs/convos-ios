import ConvosCore
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class ExplosionCoordinator {
    private let explosionWriter: any ConversationExplosionWriterProtocol

    private(set) var state: ExplodeState = .ready

    @ObservationIgnored
    private var explodeTask: Task<Void, Never>?

    init(explosionWriter: any ConversationExplosionWriterProtocol) {
        self.explosionWriter = explosionWriter
    }

    deinit {
        explodeTask?.cancel()
    }

    func explode(
        conversationId: String,
        memberInboxIds: [String],
        displayName: String,
        onExploded: @escaping () -> Void
    ) {
        guard state.isReady || state.isError || state.isScheduled else { return }

        state = .exploding

        explodeTask?.cancel()
        explodeTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await explosionWriter.explodeConversation(
                    conversationId: conversationId,
                    memberInboxIds: memberInboxIds
                )

                self.state = .exploded

                await UNUserNotificationCenter.current().addExplosionNotification(
                    conversationId: conversationId,
                    displayName: displayName
                )

                onExploded()
                Log.info("Explode complete, inbox deletion triggered")
            } catch {
                Log.error("Error exploding convo: \(error.localizedDescription)")
                self.state = .error("Explode failed")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.state = .ready
            }
        }
    }

    func scheduleExplosion(
        conversationId: String,
        expiresAt: Date,
        onImmediateExplosion: () -> Void
    ) {
        guard state.isReady || state.isError else { return }

        if expiresAt <= Date() {
            onImmediateExplosion()
            return
        }

        state = .exploding

        explodeTask?.cancel()
        explodeTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await explosionWriter.scheduleExplosion(
                    conversationId: conversationId,
                    expiresAt: expiresAt
                )

                self.state = .scheduled(expiresAt)
                Log.info("Explosion scheduled for \(expiresAt)")
            } catch {
                Log.error("Error scheduling explosion: \(error.localizedDescription)")
                self.state = .error("Schedule failed")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.state = .ready
            }
        }
    }
}
