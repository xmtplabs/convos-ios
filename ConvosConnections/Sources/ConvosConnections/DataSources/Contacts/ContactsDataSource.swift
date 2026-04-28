import Foundation
#if canImport(Contacts)
@preconcurrency import Contacts
#endif

/// Bridges the user's address book into `ConvosConnections` via the Contacts framework.
///
/// No background delivery — `CNContactStoreDidChange` only fires while the app is running.
/// The host app's `BGAppRefreshTask` handler can call `snapshotCurrent()` to pick up deltas
/// while the app is suspended.
///
/// Volume control: the emitted payload only carries total count and a bounded preview
/// (`previewLimit`) of contacts sorted by most-recently-modified. Full address-book dumps
/// would be both expensive to encode and rarely useful in a conversation.
public final class ContactsDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .contacts
    public let previewLimit: Int

    public init(previewLimit: Int = 20) {
        self.previewLimit = previewLimit
        #if canImport(Contacts)
        self.state = StateBox()
        #endif
    }

    #if canImport(Contacts)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let store = CNContactStore()
        _ = try await store.requestAccess(for: .contacts)
        return await authorizationStatus()
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        return [
            AuthorizationDetail(
                identifier: "contacts",
                displayName: "Contacts",
                status: status,
                note: nil
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        try await state.start(emit: emit, previewLimit: previewLimit)
    }

    public func stop() async {
        await state.stop()
    }

    /// One-shot snapshot. Useful for the debug view and `BGAppRefreshTask` callers.
    public func snapshotCurrent() async throws -> ContactsPayload {
        let store = CNContactStore()
        return try Self.buildPayload(store: store, previewLimit: previewLimit)
    }

    static func map(_ status: CNAuthorizationStatus) -> ConnectionAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .partial(missing: ["full-access"])
        @unknown default: return .notDetermined
        }
    }

    static func buildPayload(store: CNContactStore, previewLimit: Int) throws -> ContactsPayload {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        var total = 0
        var preview: [ContactSummary] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName
        try store.enumerateContacts(with: request) { contact, _ in
            total += 1
            if previewLimit > 0 && preview.count < previewLimit {
                preview.append(
                    ContactSummary(
                        id: contact.identifier,
                        givenName: contact.givenName.isEmpty ? nil : contact.givenName,
                        familyName: contact.familyName.isEmpty ? nil : contact.familyName,
                        organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                        hasEmail: !contact.emailAddresses.isEmpty,
                        hasPhone: !contact.phoneNumbers.isEmpty
                    )
                )
            }
        }

        let summary = "\(total) contact\(total == 1 ? "" : "s") in address book."
        return ContactsPayload(
            summary: summary,
            totalContactCount: total,
            previewContacts: preview
        )
    }

    private actor StateBox {
        private var store: CNContactStore?
        private var observerToken: NSObjectProtocol?
        private var emitter: ConnectionPayloadEmitter?
        private var previewLimit: Int = 20

        func start(emit: @escaping ConnectionPayloadEmitter, previewLimit: Int) async throws {
            if store != nil { return }
            let store = CNContactStore()
            self.store = store
            self.emitter = emit
            self.previewLimit = previewLimit

            emitCurrent(store: store)

            observerToken = NotificationCenter.default.addObserver(
                forName: .CNContactStoreDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.handleChanged()
                }
            }
        }

        func stop() async {
            if let observerToken {
                NotificationCenter.default.removeObserver(observerToken)
            }
            observerToken = nil
            store = nil
            emitter = nil
        }

        private func handleChanged() async {
            guard let store else { return }
            emitCurrent(store: store)
        }

        private func emitCurrent(store: CNContactStore) {
            guard let emitter else { return }
            do {
                let payload = try ContactsDataSource.buildPayload(store: store, previewLimit: previewLimit)
                emitter(ConnectionPayload(source: .contacts, body: .contacts(payload)))
            } catch {
                // enumeration can fail during permission transitions; silently skip.
            }
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotCurrent() async throws -> ContactsPayload {
        ContactsPayload(summary: "Contacts not available.", totalContactCount: 0, previewContacts: [])
    }
    #endif
}
