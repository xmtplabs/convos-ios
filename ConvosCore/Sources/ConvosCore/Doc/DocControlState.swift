import Foundation

public struct DocControlEvent: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        case lifecycle(DocControlLifecycle)
        case line(DocControlLine)
        case verification(DocControlVerification)
        case binding(DocControlBinding)
        case googleDocs(DocControlGoogleDocs)
    }

    public let instanceId: String
    public let epoch: String
    public let sequence: Int64
    public let occurredAt: Int64
    public let key: String
    public let payload: Payload

    public init(
        instanceId: String,
        epoch: String,
        sequence: Int64,
        occurredAt: Int64,
        key: String,
        payload: Payload
    ) {
        self.instanceId = instanceId
        self.epoch = epoch
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.key = key
        self.payload = payload
    }
}

public struct DocControlLifecycle: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case provisioned
        case joined
        case ready
        case failed
        case destroyed
    }

    public let status: Status
    public let conversationId: String?
    public let failureCode: String?

    public init(status: Status, conversationId: String?, failureCode: String?) {
        self.status = status
        self.conversationId = conversationId
        self.failureCode = failureCode
    }
}

public struct DocControlLine: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case available
        case unavailable
    }

    public let status: Status
    public let lineNumber: String?

    public init(status: Status, lineNumber: String?) {
        self.status = status
        self.lineNumber = lineNumber
    }
}

public struct DocControlVerification: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case pending
        case sent
        case sendFailed = "send_failed"
        case attemptFailed = "attempt_failed"
        case verified
        case expired
        case released
    }

    public let status: Status
    public let challengeId: String?
    public let lineNumber: String
    public let ownerNumber: String?
    public let code: String?
    public let smsBody: String?
    public let expiresAt: Int64
    public let verifiedAt: Int64?
    public let releasedAt: Int64?
    public let clearsKey: String?

    public init(
        status: Status,
        challengeId: String?,
        lineNumber: String,
        ownerNumber: String?,
        code: String?,
        smsBody: String?,
        expiresAt: Int64,
        verifiedAt: Int64?,
        releasedAt: Int64?,
        clearsKey: String?
    ) {
        self.status = status
        self.challengeId = challengeId
        self.lineNumber = lineNumber
        self.ownerNumber = ownerNumber
        self.code = code
        self.smsBody = smsBody
        self.expiresAt = expiresAt
        self.verifiedAt = verifiedAt
        self.releasedAt = releasedAt
        self.clearsKey = clearsKey
    }
}

public struct DocControlBinding: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case pending
        case live
        case released
    }

    public enum ConversationType: String, Codable, Hashable, Sendable {
        case dm
        case group
    }

    public let status: Status
    public let lineNumber: String
    public let threadId: String?
    public let conversationType: ConversationType?
    public let groupName: String?
    public let docId: String?
    public let intentAt: Int64
    public let boundAt: Int64?
    public let releasedAt: Int64?
    public let supersedesKey: String?

    public init(
        status: Status,
        lineNumber: String,
        threadId: String?,
        conversationType: ConversationType?,
        groupName: String?,
        docId: String?,
        intentAt: Int64,
        boundAt: Int64?,
        releasedAt: Int64?,
        supersedesKey: String?
    ) {
        self.status = status
        self.lineNumber = lineNumber
        self.threadId = threadId
        self.conversationType = conversationType
        self.groupName = groupName
        self.docId = docId
        self.intentAt = intentAt
        self.boundAt = boundAt
        self.releasedAt = releasedAt
        self.supersedesKey = supersedesKey
    }
}

public struct DocControlGoogleDocs: Codable, Hashable, Sendable {
    public struct Gate: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable {
            case idle
            case pending
            case approved
            case denied
            case cancelled
        }

        public let status: Status
        public let requestId: String?
        public let updatedAt: Int64

        public init(status: Status, requestId: String?, updatedAt: Int64) {
            self.status = status
            self.requestId = requestId
            self.updatedAt = updatedAt
        }
    }

    public struct Connection: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable {
            case unknown
            case granted
            case revoked
        }

        public let status: Status
        public let providerId: String?
        public let updatedAt: Int64

        public init(status: Status, providerId: String?, updatedAt: Int64) {
            self.status = status
            self.providerId = providerId
            self.updatedAt = updatedAt
        }
    }

    public let ownerInboxId: String?
    public let requestConversationId: String?
    public let supersedesKey: String?
    public let gate: Gate
    public let connection: Connection

    public init(
        ownerInboxId: String?,
        requestConversationId: String?,
        supersedesKey: String?,
        gate: Gate,
        connection: Connection
    ) {
        self.ownerInboxId = ownerInboxId
        self.requestConversationId = requestConversationId
        self.supersedesKey = supersedesKey
        self.gate = gate
        self.connection = connection
    }
}

public struct DocControlSnapshot: Codable, Hashable, Sendable {
    public let instanceId: String
    public let epoch: String
    public private(set) var latestSequencesByKey: [String: Int64]
    public private(set) var lifecycle: DocControlLifecycle?
    public private(set) var line: DocControlLine?
    public private(set) var verificationsByKey: [String: DocControlVerification]
    public private(set) var bindingsByKey: [String: DocControlBinding]
    public private(set) var googleDocsByKey: [String: DocControlGoogleDocs]

    public init(instanceId: String, epoch: String) {
        self.instanceId = instanceId
        self.epoch = epoch
        self.latestSequencesByKey = [:]
        self.lifecycle = nil
        self.line = nil
        self.verificationsByKey = [:]
        self.bindingsByKey = [:]
        self.googleDocsByKey = [:]
    }

    public init(event: DocControlEvent) {
        self.init(instanceId: event.instanceId, epoch: event.epoch)
        _ = apply(event)
    }

    @discardableResult
    public mutating func apply(_ event: DocControlEvent) -> Bool {
        guard event.instanceId == instanceId, event.epoch == epoch else { return false }
        var changed = false
        if event.sequence > (latestSequencesByKey[event.key] ?? 0) {
            latestSequencesByKey[event.key] = event.sequence
            switch event.payload {
            case .lifecycle(let value):
                lifecycle = value
            case .line(let value):
                line = value
            case .verification(let value):
                verificationsByKey[event.key] = value
            case .binding(let value):
                bindingsByKey[event.key] = value
            case .googleDocs(let value):
                googleDocsByKey[event.key] = value
            }
            changed = true
        }

        switch event.payload {
        case .verification(let value):
            if let clearsKey = value.clearsKey,
               applySupersession(key: clearsKey, sequence: event.sequence) {
                verificationsByKey[clearsKey] = nil
                changed = true
            }
        case .binding(let value):
            if let supersedesKey = value.supersedesKey,
               applySupersession(key: supersedesKey, sequence: event.sequence) {
                bindingsByKey[supersedesKey] = nil
                changed = true
            }
        case .googleDocs(let value):
            if let supersedesKey = value.supersedesKey,
               applySupersession(key: supersedesKey, sequence: event.sequence) {
                googleDocsByKey[supersedesKey] = nil
                changed = true
            }
        case .lifecycle, .line:
            break
        }
        return changed
    }

    public var verificationChallenge: DocControlVerification? {
        verificationsByKey[DocControlMessage.verificationChallengeKey]
    }

    public func binding(forDocId docId: String) -> DocControlBinding? {
        bindingsByKey
            .filter { $0.value.docId == docId }
            .max { lhs, rhs in
                (latestSequencesByKey[lhs.key] ?? 0) < (latestSequencesByKey[rhs.key] ?? 0)
            }?
            .value
    }

    public func googleDocs(ownerInboxId: String) -> DocControlGoogleDocs? {
        if let value = googleDocsByKey["google:\(ownerInboxId)"] { return value }
        return googleDocsByKey
            .filter { $0.value.ownerInboxId == nil }
            .max { lhs, rhs in
                (latestSequencesByKey[lhs.key] ?? 0) < (latestSequencesByKey[rhs.key] ?? 0)
            }?
            .value
    }

    private mutating func applySupersession(
        key: String,
        sequence: Int64
    ) -> Bool {
        guard sequence > (latestSequencesByKey[key] ?? 0) else { return false }
        latestSequencesByKey[key] = sequence
        return true
    }
}

public enum DocControlRequestMessage {
    public static let resyncText: String = #"⟦req⟧{"v":1,"t":"control"}"#
    public static let renewVerificationText: String = #"⟦req⟧{"v":1,"t":"control","action":"renew_verification"}"#

    public static func verifyRequestText(number: String) -> String? {
        guard isE164(number) else { return nil }
        return #"⟦req⟧{"v":1,"t":"verify_request","number":"\#(number)"}"#
    }

    public static func verifySubmitText(code: String) -> String? {
        guard code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else { return nil }
        return #"⟦req⟧{"v":1,"t":"verify_submit","code":"\#(code)"}"#
    }

    private static func isE164(_ value: String) -> Bool {
        value.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil
    }
}

public enum DocControlMessage {
    public static let prefix: String = "⟦doc⟧"
    public static let verificationChallengeKey: String = "verification:challenge"
    public static let verificationRequestKey: String = "verification:request"

    public static func parseEvent(_ text: String) -> DocControlEvent? {
        guard text.hasPrefix(prefix), text.utf8.count <= Constant.maximumWireBytes else { return nil }
        let payload = text.dropFirst(prefix.count)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let type = json["t"] as? String,
              type == "control",
              let kind = json["kind"] as? String,
              validateShape(json, kind: kind),
              let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data),
              envelope.version == 1,
              envelope.type == "control",
              isUUID(envelope.instanceId),
              isUUID(envelope.epoch),
              (1...Constant.maximumSafeJSONInteger).contains(envelope.sequence),
              envelope.occurredAt >= 0,
              isBoundedIdentity(envelope.key),
              let eventPayload = validatedPayload(envelope, kind: kind) else {
            return nil
        }
        return DocControlEvent(
            instanceId: envelope.instanceId,
            epoch: envelope.epoch,
            sequence: envelope.sequence,
            occurredAt: envelope.occurredAt,
            key: envelope.key,
            payload: eventPayload
        )
    }

    private static func validatedPayload(_ envelope: RawEnvelope, kind: String) -> DocControlEvent.Payload? {
        switch kind {
        case "lifecycle":
            guard envelope.key == "lifecycle", let value = envelope.lifecycle, validate(value) else { return nil }
            return .lifecycle(value)
        case "line":
            guard envelope.key == "line", let value = envelope.line, validate(value) else { return nil }
            return .line(value)
        case "verification":
            guard let value = envelope.verification, validate(value, key: envelope.key) else { return nil }
            return .verification(value)
        case "binding":
            guard let value = envelope.binding, validate(value, key: envelope.key) else { return nil }
            return .binding(value)
        case "google_docs":
            guard let value = envelope.googleDocs, validate(value, key: envelope.key) else { return nil }
            return .googleDocs(value)
        default:
            return nil
        }
    }

    private static func validate(_ value: DocControlLifecycle) -> Bool {
        let hasConversation = value.conversationId.map(isBoundedIdentity) ?? false
        let validFailureCode = value.failureCode.map {
            !$0.isEmpty && $0.utf8.count <= 64 && $0.unicodeScalars.allSatisfy(\.isASCII)
        } ?? false
        switch value.status {
        case .provisioned:
            return value.conversationId == nil && value.failureCode == nil
        case .joined, .ready, .destroyed:
            return hasConversation && value.failureCode == nil
        case .failed:
            return (value.conversationId == nil || hasConversation) && validFailureCode
        }
    }

    private static func validate(_ value: DocControlLine) -> Bool {
        switch value.status {
        case .available:
            return value.lineNumber.map(isE164) == true
        case .unavailable:
            return value.lineNumber == nil
        }
    }

    private static func validate(_ value: DocControlVerification, key: String) -> Bool {
        guard isE164(value.lineNumber),
              value.expiresAt >= 0,
              value.challengeId.map(isUUID) ?? true else {
            return false
        }
        switch value.status {
        case .pending:
            guard key == verificationChallengeKey,
                  value.challengeId.map(isUUID) == true,
                  value.ownerNumber == nil,
                  let code = value.code,
                  isVerificationCode(code),
                  value.smsBody == "VERIFY \(code)",
                  value.verifiedAt == nil,
                  value.releasedAt == nil,
                  value.clearsKey == nil else {
                return false
            }
            return true
        case .sent, .sendFailed, .attemptFailed:
            guard key == verificationRequestKey,
                  let ownerNumber = value.ownerNumber,
                  isE164(ownerNumber),
                  value.code == nil,
                  value.smsBody == nil,
                  value.verifiedAt == nil,
                  value.releasedAt == nil,
                  value.clearsKey == nil else {
                return false
            }
            return value.status == .sendFailed || value.challengeId.map(isUUID) == true
        case .verified:
            guard value.challengeId != nil,
                  let ownerNumber = value.ownerNumber,
                  isE164(ownerNumber),
                  key == "verification:owner:\(ownerNumber)",
                  value.code == nil,
                  value.smsBody == nil,
                  value.verifiedAt.map({ $0 >= 0 }) == true,
                  value.releasedAt == nil,
                  let clearsKey = value.clearsKey,
                  [verificationChallengeKey, verificationRequestKey].contains(clearsKey) else {
                return false
            }
            return true
        case .expired:
            return key == verificationChallengeKey &&
                value.challengeId.map(isUUID) == true &&
                value.ownerNumber == nil &&
                value.code == nil &&
                value.smsBody == nil &&
                value.verifiedAt == nil &&
                value.releasedAt == nil &&
                value.clearsKey == nil
        case .released:
            guard value.challengeId.map(isUUID) ?? true,
                  let ownerNumber = value.ownerNumber,
                  isE164(ownerNumber),
                  key == "verification:owner:\(ownerNumber)",
                  value.code == nil,
                  value.smsBody == nil,
                  value.verifiedAt.map({ $0 >= 0 }) ?? true,
                  value.releasedAt.map({ $0 >= 0 }) == true,
                  value.clearsKey == nil else {
                return false
            }
            return true
        }
    }

    private static func validate(_ value: DocControlBinding, key: String) -> Bool {
        guard isE164(value.lineNumber), value.intentAt >= 0,
              value.groupName.map({ !$0.isEmpty && $0.unicodeScalars.count <= 200 }) ?? true,
              value.docId.map(isDocSlug) ?? true else {
            return false
        }
        switch value.status {
        case .pending:
            guard let docId = value.docId else { return false }
            return key == "binding:doc:\(docId)" &&
                value.threadId == nil &&
                value.conversationType == nil &&
                value.groupName == nil &&
                value.boundAt == nil &&
                value.releasedAt == nil &&
                value.supersedesKey == nil
        case .live:
            guard let threadId = value.threadId,
                  isBoundedIdentity(threadId),
                  value.conversationType != nil,
                  value.boundAt.map({ $0 >= 0 }) == true,
                  value.releasedAt == nil,
                  key == "binding:thread:\(value.lineNumber):\(threadId)" else {
                return false
            }
            return validateBindingSupersession(value)
        case .released:
            guard let threadId = value.threadId,
                  isBoundedIdentity(threadId),
                  value.conversationType != nil,
                  value.boundAt.map({ $0 >= 0 }) == true,
                  value.releasedAt.map({ $0 >= 0 }) == true,
                  value.supersedesKey == nil else {
                return false
            }
            return key == "binding:thread:\(value.lineNumber):\(threadId)"
        }
    }

    private static func validateBindingSupersession(_ value: DocControlBinding) -> Bool {
        guard let supersedesKey = value.supersedesKey else { return true }
        guard let docId = value.docId else { return false }
        return supersedesKey == "binding:doc:\(docId)"
    }

    private static func validate(_ value: DocControlGoogleDocs, key: String) -> Bool {
        guard let factIdentity = value.ownerInboxId ?? value.requestConversationId,
              isBoundedIdentity(factIdentity),
              key == "google:\(factIdentity)",
              value.ownerInboxId.map(isBoundedIdentity) ?? true,
              value.requestConversationId.map(isBoundedIdentity) ?? true,
              validate(value.gate),
              validate(value.connection) else {
            return false
        }
        guard let supersedesKey = value.supersedesKey else { return true }
        return supersedesKey.hasPrefix("google:") && isBoundedIdentity(String(supersedesKey.dropFirst(7)))
    }

    private static func validate(_ gate: DocControlGoogleDocs.Gate) -> Bool {
        guard gate.updatedAt >= 0 else { return false }
        switch gate.status {
        case .idle:
            return gate.requestId == nil
        case .pending, .approved, .denied, .cancelled:
            return gate.requestId.map(isBoundedIdentity) == true
        }
    }

    private static func validate(_ connection: DocControlGoogleDocs.Connection) -> Bool {
        guard connection.updatedAt >= 0 else { return false }
        switch connection.status {
        case .unknown:
            return connection.providerId == nil
        case .granted, .revoked:
            return connection.providerId == Constant.googleDocsProviderId
        }
    }

    private static func validateShape(_ json: [String: Any], kind: String) -> Bool {
        let payloadKey: String
        let payloadKeys: Set<String>
        switch kind {
        case "lifecycle":
            payloadKey = "lifecycle"
            payloadKeys = ["status", "conversationId", "failureCode"]
        case "line":
            payloadKey = "line"
            payloadKeys = ["status", "lineNumber"]
        case "verification":
            payloadKey = "verification"
            payloadKeys = [
                "status", "challengeId", "lineNumber", "ownerNumber", "code", "smsBody",
                "expiresAt", "verifiedAt", "releasedAt", "clearsKey",
            ]
        case "binding":
            payloadKey = "binding"
            payloadKeys = [
                "status", "lineNumber", "threadId", "conversationType", "groupName", "docId",
                "intentAt", "boundAt", "releasedAt", "supersedesKey",
            ]
        case "google_docs":
            payloadKey = "googleDocs"
            payloadKeys = ["ownerInboxId", "requestConversationId", "supersedesKey", "gate", "connection"]
        default:
            return false
        }
        let commonKeys: Set<String> = ["v", "t", "instanceId", "epoch", "seq", "at", "key", "kind"]
        guard Set(json.keys) == commonKeys.union([payloadKey]),
              let payload = json[payloadKey] as? [String: Any],
              Set(payload.keys) == payloadKeys else {
            return false
        }
        guard kind == "google_docs" else { return true }
        guard let gate = payload["gate"] as? [String: Any],
              Set(gate.keys) == ["status", "requestId", "updatedAt"],
              let connection = payload["connection"] as? [String: Any],
              Set(connection.keys) == ["status", "providerId", "updatedAt"] else {
            return false
        }
        return true
    }

    private static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func isE164(_ value: String) -> Bool {
        value.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil
    }

    private static func isVerificationCode(_ value: String) -> Bool {
        value.range(of: #"^[A-Z2-9]{4}(?:-[A-Z2-9]{4}){2}$"#, options: .regularExpression) != nil
    }

    private static func isDocSlug(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func isBoundedIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }

    private struct RawEnvelope: Decodable {
        let version: Int
        let type: String
        let instanceId: String
        let epoch: String
        let sequence: Int64
        let occurredAt: Int64
        let key: String
        let lifecycle: DocControlLifecycle?
        let line: DocControlLine?
        let verification: DocControlVerification?
        let binding: DocControlBinding?
        let googleDocs: DocControlGoogleDocs?

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case type = "t"
            case instanceId
            case epoch
            case sequence = "seq"
            case occurredAt = "at"
            case key
            case lifecycle
            case line
            case verification
            case binding
            case googleDocs
        }
    }

    private enum Constant {
        static let maximumWireBytes: Int = 4_096
        static let maximumSafeJSONInteger: Int64 = 9_007_199_254_740_991
        static let googleDocsProviderId: String = "composio.googledocs"
    }
}
