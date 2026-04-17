import Foundation
#if canImport(Contacts)
@preconcurrency import Contacts
#endif

/// Write-side counterpart to `ContactsDataSource`.
///
/// Supports `create_contact`, `update_contact`, `delete_contact` via `CNSaveRequest` against
/// a private `CNContactStore`. Phone and email are modelled as a single primary value per
/// action; multi-value editing is intentionally out of scope for v1 — agents that need it
/// can issue multiple `update_contact` calls or wait for a richer schema.
public final class ContactsDataSink: DataSink, @unchecked Sendable {
    public let kind: ConnectionKind = .contacts

    public init() {
        #if canImport(Contacts)
        self.state = StateBox()
        #endif
    }

    public func actionSchemas() async -> [ActionSchema] {
        ContactsActionSchemas.all
    }

    #if canImport(Contacts)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        ContactsDataSource.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let store = CNContactStore()
        _ = try await store.requestAccess(for: .contacts)
        return await authorizationStatus()
    }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        await state.invoke(invocation)
    }

    private actor StateBox {
        private let store: CNContactStore = CNContactStore()

        func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
            switch invocation.action.name {
            case ContactsActionSchemas.createContact.actionName:
                return createContact(invocation)
            case ContactsActionSchemas.updateContact.actionName:
                return updateContact(invocation)
            case ContactsActionSchemas.deleteContact.actionName:
                return deleteContact(invocation)
            default:
                return Self.makeResult(
                    for: invocation,
                    status: .unknownAction,
                    errorMessage: "Contacts sink does not know action '\(invocation.action.name)'."
                )
            }
        }

        private func createContact(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Contacts access is not granted.")
            }

            let args = invocation.action.arguments
            let contact = CNMutableContact()
            if let value = args["givenName"]?.stringValue { contact.givenName = value }
            if let value = args["familyName"]?.stringValue { contact.familyName = value }
            if let value = args["organization"]?.stringValue { contact.organizationName = value }
            if let value = args["phone"]?.stringValue, !value.isEmpty {
                contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: value))]
            }
            if let value = args["email"]?.stringValue, !value.isEmpty {
                contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: value as NSString)]
            }
            if let value = args["note"]?.stringValue {
                contact.note = value
            }

            guard !contact.givenName.isEmpty || !contact.familyName.isEmpty || !contact.organizationName.isEmpty else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "At least one of givenName, familyName, or organization is required.")
            }

            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            do {
                try store.execute(request)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }
            return Self.makeResult(
                for: invocation,
                status: .success,
                result: ["contactId": .string(contact.identifier)]
            )
        }

        private func updateContact(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Contacts access is not granted.")
            }
            let args = invocation.action.arguments
            guard let contactId = args["contactId"]?.stringValue else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'contactId'.")
            }

            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactNoteKey as CNKeyDescriptor,
            ]

            let mutable: CNMutableContact
            do {
                let fetched = try store.unifiedContact(withIdentifier: contactId, keysToFetch: keys)
                guard let copy = fetched.mutableCopy() as? CNMutableContact else {
                    return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not load contact for editing.")
                }
                mutable = copy
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Contact not found for id '\(contactId)'.")
            }

            if let value = args["givenName"]?.stringValue { mutable.givenName = value }
            if let value = args["familyName"]?.stringValue { mutable.familyName = value }
            if let value = args["organization"]?.stringValue { mutable.organizationName = value }
            if let value = args["phone"]?.stringValue {
                mutable.phoneNumbers = value.isEmpty
                    ? []
                    : [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: value))]
            }
            if let value = args["email"]?.stringValue {
                mutable.emailAddresses = value.isEmpty
                    ? []
                    : [CNLabeledValue(label: CNLabelHome, value: value as NSString)]
            }
            if let value = args["note"]?.stringValue {
                mutable.note = value
            }

            let request = CNSaveRequest()
            request.update(mutable)
            do {
                try store.execute(request)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }
            return Self.makeResult(
                for: invocation,
                status: .success,
                result: ["contactId": .string(mutable.identifier)]
            )
        }

        private func deleteContact(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Contacts access is not granted.")
            }
            let args = invocation.action.arguments
            guard let contactId = args["contactId"]?.stringValue else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'contactId'.")
            }

            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            let mutable: CNMutableContact
            do {
                let fetched = try store.unifiedContact(withIdentifier: contactId, keysToFetch: keys)
                guard let copy = fetched.mutableCopy() as? CNMutableContact else {
                    return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not load contact for deletion.")
                }
                mutable = copy
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Contact not found for id '\(contactId)'.")
            }

            let request = CNSaveRequest()
            request.delete(mutable)
            do {
                try store.execute(request)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }
            return Self.makeResult(for: invocation, status: .success)
        }

        private static func makeResult(
            for invocation: ConnectionInvocation,
            status: ConnectionInvocationResult.Status,
            errorMessage: String? = nil,
            result: [String: ArgumentValue] = [:]
        ) -> ConnectionInvocationResult {
            ConnectionInvocationResult(
                invocationId: invocation.invocationId,
                kind: invocation.kind,
                actionName: invocation.action.name,
                status: status,
                result: result,
                errorMessage: errorMessage
            )
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: .contacts,
            actionName: invocation.action.name,
            status: .executionFailed,
            errorMessage: "Contacts not available on this platform."
        )
    }
    #endif
}
