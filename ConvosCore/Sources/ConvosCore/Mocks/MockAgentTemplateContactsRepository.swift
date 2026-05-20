import Combine
import Foundation

/// Mock agent-template contacts repository for previews and the mock
/// messaging service. Mirrors `MockContactsRepository`.
public final class MockAgentTemplateContactsRepository: AgentTemplateContactsRepositoryProtocol, @unchecked Sendable {
    private let subject: CurrentValueSubject<[AgentTemplateContact], Never>

    public var agentTemplateContactsPublisher: AnyPublisher<[AgentTemplateContact], Never> {
        subject.eraseToAnyPublisher()
    }

    public init(contacts: [AgentTemplateContact] = MockAgentTemplateContactsRepository.defaultMockContacts) {
        self.subject = .init(contacts)
    }

    public func fetchAll() throws -> [AgentTemplateContact] {
        subject.value
    }

    public func fetchContact(templateId: String) throws -> AgentTemplateContact? {
        subject.value.first { $0.templateId == templateId }
    }

    public func isContact(templateId: String) throws -> Bool {
        subject.value.contains { $0.templateId == templateId }
    }

    public func setContacts(_ contacts: [AgentTemplateContact]) {
        subject.send(contacts)
    }

    public static let defaultMockContacts: [AgentTemplateContact] = [
        .mock(displayName: "Tifoso", emoji: "🚴"),
        .mock(displayName: "Trip Planner", emoji: "🗺️"),
    ]
}

public final class MockAgentTemplateContactsWriter: AgentTemplateContactsWriterProtocol, @unchecked Sendable {
    public init() {}

    public func upsert(
        templateId: String,
        addedViaConversationId: String?,
        profile: AgentTemplateContactSnapshot
    ) async throws {}

    public func remove(templateId: String) async throws {}
}
