import Foundation

struct EmptyResponse: Decodable {}

public enum ConvosAPI {
    public struct FetchJwtResponse: Codable {
        public let token: String
    }

    // MARK: - v2/auth/token (SIWE)

    /// Request body for `POST /api/v2/auth/token`. Omit `siwe` for the
    /// legacy device-only path; include it to bind the JWT to an
    /// Ethereum account.
    public struct AuthTokenRequest: Encodable {
        public let deviceId: String
        public let siwe: SIWEPayload?

        public init(deviceId: String, siwe: SIWEPayload?) {
            self.deviceId = deviceId
            self.siwe = siwe
        }
    }

    public struct SIWEPayload: Encodable {
        public let message: String
        public let signature: String

        public init(message: String, signature: String) {
            self.message = message
            self.signature = signature
        }
    }

    public struct AuthTokenResponse: Decodable {
        public let token: String

        public init(token: String) { self.token = token }
    }

    // MARK: - Device Update Models

    struct DeviceUpdateRequest: Codable {
        let pushToken: String
        let pushTokenType: DeviceUpdatePushTokenType
        let apnsEnv: DeviceUpdateApnsEnvironment

        enum DeviceUpdatePushTokenType: String, Codable {
            case apns
        }

        enum DeviceUpdateApnsEnvironment: String, Codable {
            case sandbox
            case production
        }

        init(pushToken: String,
             pushTokenType: DeviceUpdatePushTokenType = .apns,
             apnsEnv: DeviceUpdateApnsEnvironment) {
            self.pushToken = pushToken
            self.pushTokenType = pushTokenType
            self.apnsEnv = apnsEnv
        }
    }
    public struct DeviceUpdateResponse: Codable {
        public let id: String
        public let pushToken: String?
        public let pushTokenType: String
        public let apnsEnv: String?
        public let updatedAt: String
        public let pushFailures: Int
    }

    public struct AuthCheckResponse: Codable {
        public let success: Bool
    }

    // MARK: - v2 Device & Notification Endpoints

    public enum PushTokenType: String, Codable {
        case apns
        case fcm
    }

    // MARK: - v2/device/register
    // POST /v2/device/register
    // Purpose: Register or update device metadata (independent of push notifications)
    // Returns: 200 with empty body on success
    // Errors: 400 (invalid body), 403 (device disabled), 500 (server error)

    public struct RegisterDeviceRequest: Codable {
        public let deviceId: String
        public let pushToken: String?
        public let pushTokenType: String?
        public let apnsEnv: String?

        public init(deviceId: String, pushToken: String?, pushTokenType: String?, apnsEnv: String?) {
            self.deviceId = deviceId
            self.pushToken = pushToken
            self.pushTokenType = pushTokenType
            self.apnsEnv = apnsEnv
        }
    }

    // MARK: - v2/notifications/subscribe
    // POST /v2/notifications/subscribe
    // Returns: 200 with empty body on success
    // Errors: 400 (invalid body), 404 (device not found), 403 (device disabled), 500 (server error)

    public struct HmacKey: Codable {
        public let thirtyDayPeriodsSinceEpoch: Int
        public let key: String // hex string

        public init(thirtyDayPeriodsSinceEpoch: Int, key: String) {
            self.thirtyDayPeriodsSinceEpoch = thirtyDayPeriodsSinceEpoch
            self.key = key
        }
    }

    public struct TopicSubscription: Codable {
        public let topic: String
        public let hmacKeys: [HmacKey]

        public init(topic: String, hmacKeys: [HmacKey]) {
            self.topic = topic
            self.hmacKeys = hmacKeys
        }
    }

    public struct SubscribeRequest: Codable {
        public let deviceId: String
        public let clientId: String
        public let topics: [TopicSubscription]

        public init(deviceId: String, clientId: String, topics: [TopicSubscription]) {
            self.deviceId = deviceId
            self.clientId = clientId
            self.topics = topics
        }
    }

    // MARK: - v2/notifications/unsubscribe
    // POST /v2/notifications/unsubscribe
    // Returns: 200 with empty body on success
    // Errors: 400 (invalid body), 404 (client not found), 500 (server error)

    public struct UnsubscribeRequest: Codable {
        public let clientId: String
        public let topics: [String]

        public init(clientId: String, topics: [String]) {
            self.clientId = clientId
            self.topics = topics
        }
    }

    // MARK: - v2/notifications/unregister
    // DELETE /v2/notifications/unregister/:clientId
    // clientId is a URL parameter, not in body
    // Returns: 200 with empty body on success
    // Errors: 400 (invalid params), 404 (client not found), 500 (server error)

    // MARK: - v2/agents/join
    // POST /v2/agents/join
    // The body is validated strictly server-side: unknown keys are rejected.
    // `templateId` is optional - omitting it requests a bare join (the
    // backend provisions a default agent). Nil optionals are omitted from
    // the encoded JSON by Codable's synthesized encoder.
    //
    // Exactly one of `slug` (invite flow) or `conversationId` (direct-add).
    // In direct-add mode the backend provisions the agent and responds with
    // its `inboxId`; the client adds that inbox to the declared group with
    // addMembers and is done — the runtime observes the resulting group
    // welcome and attaches, with no confirmation call.

    /// Idempotency key for `POST /v2/agents/join`: a lowercase v4 UUID stable
    /// across retries of one logical join. The assistants service uses it as
    /// the workflow instance id, so a retry of a join whose response was lost
    /// adopts the already-provisioned instance instead of creating a duplicate.
    ///
    /// A dedicated type rather than `String` so another identifier (e.g. the
    /// generation idempotency key, which is uppercase) cannot be wired in by
    /// accident, and rather than Foundation's `UUID` because `UUID` encodes as
    /// its uppercase `uuidString` while the server contract is lowercase-only
    /// (the key becomes the assistant instance id).
    public struct JoinIdempotencyKey: Hashable, Sendable, Codable {
        public let rawValue: String

        /// Mints a fresh key - the only way to produce a new key value.
        public static func mint() -> JoinIdempotencyKey {
            JoinIdempotencyKey(validated: UUID().uuidString.lowercased())
        }

        /// Rehydrates a persisted key, normalizing to lowercase; `nil` for
        /// anything that is not a UUID.
        public init?(rawValue: String) {
            guard UUID(uuidString: rawValue) != nil else { return nil }
            self.init(validated: rawValue.lowercased())
        }

        private init(validated: String) {
            rawValue = validated
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let key = JoinIdempotencyKey(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid join idempotency key: \(raw)")
            }
            self = key
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public struct AgentJoinRequest: Codable {
        public let slug: String?
        public let conversationId: String?
        public let templateId: String?
        /// Optional and nil-omitted by Codable, so default joins stay
        /// byte-identical and the wire format remains backward-compatible.
        public let idempotencyKey: JoinIdempotencyKey?
        public let options: AgentJoinOptions?
        /// IANA timezone identifier (e.g. "Europe/Paris") carrying the
        /// conversation creator's device timezone, used by the agent runtime as
        /// the conversation's baseline/default. Distinct from the per-sender
        /// "timezone" key in ProfileUpdate.metadata, which reflects each
        /// member's own current device timezone: this one is set once at join
        /// time and does not track travel or DST. Optional and nil-omitted by
        /// Codable, so the wire format stays backward-compatible until the
        /// backend reads it.
        public let timezone: String?

        public init(
            slug: String? = nil,
            conversationId: String? = nil,
            templateId: String? = nil,
            idempotencyKey: JoinIdempotencyKey? = nil,
            options: AgentJoinOptions? = nil,
            timezone: String? = nil
        ) {
            self.slug = slug
            self.conversationId = conversationId
            self.templateId = templateId
            self.idempotencyKey = idempotencyKey
            self.options = options
            self.timezone = timezone
        }
    }

    /// Per-request hints to the agent pool. Currently the only knob is
    /// `onboarding`, which signals which client flow is requesting the
    /// join. The backend uses it to pick the right system prompt /
    /// behavior set — e.g. the Agent Builder asks for the
    /// builder-specific onboarding so the agent introduces itself in
    /// the contact-card "Learning more about my job" voice rather than
    /// the generic chat persona.
    public struct AgentJoinOptions: Codable, Sendable {
        public let onboarding: String?
        /// Dev-only agent variant slug, routing the join to the variant's
        /// ephemeral worker (`variant.assistantWorkerUrl`) server-side. Nested
        /// here (not top-level) because the join schema is `.strict()`; omitted
        /// from the encoded body when `nil` (via `encodeIfPresent`) so default
        /// joins stay byte-identical. The backend strips it before forwarding to
        /// the worker.
        public let variantId: String?

        public init(onboarding: String?, variantId: String? = nil) {
            self.onboarding = onboarding
            self.variantId = variantId
        }

        public static let agentBuilder: AgentJoinOptions = AgentJoinOptions(onboarding: "agent-builder")
    }

    public struct AgentJoinResponse: Codable {
        public let success: Bool
        public let joined: Bool
        /// Populated on every dispatch; required for the join-status poll.
        public let instanceId: String?
        /// Direct-add only: the agent's XMTP inbox to add with addMembers.
        /// Nil when registration outlasted the backend's wait budget — poll
        /// GET /v2/agents/join/:instanceId until it lands.
        public let inboxId: String?

        public init(success: Bool, joined: Bool, instanceId: String? = nil, inboxId: String? = nil) {
            self.success = success
            self.joined = joined
            self.instanceId = instanceId
            self.inboxId = inboxId
        }
    }

    // MARK: - v2/agents/join/:instanceId

    public struct AgentJoinStatusResponse: Codable {
        public let success: Bool
        public let instanceId: String
        public let joinStatus: String
        public let joined: Bool
        public let inboxId: String?
        public let conversationId: String?
        public let joinFailureReason: String?

        public init(
            success: Bool,
            instanceId: String,
            joinStatus: String,
            joined: Bool,
            inboxId: String? = nil,
            conversationId: String? = nil,
            joinFailureReason: String? = nil
        ) {
            self.success = success
            self.instanceId = instanceId
            self.joinStatus = joinStatus
            self.joined = joined
            self.inboxId = inboxId
            self.conversationId = conversationId
            self.joinFailureReason = joinFailureReason
        }

        /// Typed view of the wire `joinStatus`. Switch over this (not the
        /// raw string) so a terminal backend status can't be silently
        /// missed at the call site.
        public var provisionStatus: AgentProvisionStatus {
            AgentProvisionStatus(wire: joinStatus)
        }
    }

    // MARK: - v2/agents/:instanceId/participation

    /// Partial update: send the level, the cooldown, or both. Omitted fields
    /// are left as they are, so changing the cooldown does not disturb the
    /// level and vice versa.
    public struct AgentParticipationRequest: Codable {
        /// "speak", "mention" or "paused".
        public let mode: String?
        /// Explicit burst hold in seconds. 0 turns the explicit hold off and
        /// returns the agent to the automatic, member-scaled window.
        public let cooldownSeconds: Int?

        public init(mode: String? = nil, cooldownSeconds: Int? = nil) {
            self.mode = mode
            self.cooldownSeconds = cooldownSeconds
        }
    }

    public struct AgentParticipationResponse: Codable {
        public let success: Bool
        public let instanceId: String
        /// Echo of what was applied; nil for a field the request left alone.
        public let mode: String?
        public let cooldownSeconds: Int?

        public init(
            success: Bool,
            instanceId: String,
            mode: String? = nil,
            cooldownSeconds: Int? = nil
        ) {
            self.success = success
            self.instanceId = instanceId
            self.mode = mode
            self.cooldownSeconds = cooldownSeconds
        }
    }

    // MARK: - v2/agent-templates/:id

    // Subset of the agent-template object the backend returns from the
    // publish endpoint (POST /:id/publish). We only model the fields the
    // share flow consumes today (id, status, publishedUrl); decoding is
    // tolerant of extra keys via the default Codable behavior.
    public struct AgentTemplate: Codable, Sendable {
        public let id: String
        public let status: String
        public let publishedUrl: String?
        /// Public profile fields, populated by the detail endpoint
        /// (`GET /v2/agent-templates/:idOrUrlSlug`). Optional because the
        /// publish response historically only carried id/status/publishedUrl.
        public let slug: String?
        public let agentName: String?
        public let description: String?
        public let emoji: String?
        public let avatarUrl: String?

        public init(
            id: String,
            status: String,
            publishedUrl: String?,
            slug: String? = nil,
            agentName: String? = nil,
            description: String? = nil,
            emoji: String? = nil,
            avatarUrl: String? = nil
        ) {
            self.id = id
            self.status = status
            self.publishedUrl = publishedUrl
            self.slug = slug
            self.agentName = agentName
            self.description = description
            self.emoji = emoji
            self.avatarUrl = avatarUrl
        }
    }

    /// One page of the agent-templates list endpoint
    /// (`GET /v2/agent-templates/`). The backend returns a cursor-paginated
    /// envelope: `data` is the page, `hasMore` signals another page exists,
    /// and `nextCursor` is the opaque base64url cursor to pass back as
    /// `&cursor=` for the following page (`nil` on the last page).
    public struct AgentTemplatesPage: Codable, Sendable {
        public let data: [AgentTemplate]
        public let hasMore: Bool
        public let nextCursor: String?

        public init(data: [AgentTemplate], hasMore: Bool, nextCursor: String?) {
            self.data = data
            self.hasMore = hasMore
            self.nextCursor = nextCursor
        }
    }

    /// Response envelope for `GET /v2/agent-prompt-hints` -- a flat list of
    /// curated prompt strings (each <= 350 chars) the agent builder's dice
    /// control drops into the "What needs done?" composer. Public and
    /// unauthenticated; decoding is tolerant of extra keys via default Codable
    /// behavior.
    public struct AgentPromptHintsResponse: Codable, Sendable {
        public let hints: [String]

        public init(hints: [String]) {
            self.hints = hints
        }
    }

    // MARK: - Common Error Response

    public struct ErrorResponse: Codable {
        public let error: String
        public let details: [ValidationError]?
        public let hint: String?
    }

    public struct ValidationError: Codable {
        public let code: String
        public let expected: String?
        public let received: String?
        public let path: [String]
        public let message: String
    }

    // MARK: - v2/assets/renew-batch
    // POST /v2/assets/renew-batch
    // Purpose: Renew (copy-to-self) multiple S3 assets to reset their lifecycle expiration
    // Returns: 200 with BatchRenewResponse body
    // Errors: 400 (invalid body), 401 (unauthorized), 500 (server error)

    struct BatchRenewRequest: Codable {
        let assetKeys: [String]
    }

    struct BatchRenewResponse: Codable {
        let renewed: Int
        let failed: Int
        let results: [AssetResult]

        struct AssetResult: Codable {
            let key: String
            let success: Bool
            let error: String?
        }
    }

    // MARK: - IAP Subscription verify

    /// Verify body is just the signed Apple JWS. The `appAccountToken` lives
    /// inside the signed payload and the backend extracts it from there + binds
    /// it to the JWT-authenticated account on first call; sending it in the
    /// body too would let a caller claim someone else's transaction.
    struct VerifySubscriptionRequest: Encodable {
        let jwsRepresentation: String
        let platform: String = "apple"
    }

    struct VerifySubscriptionResponse: Decodable {
        let subscription: UserSubscription
    }
}

// MARK: - Asset Renewal Result

public struct AssetRenewalResult: Sendable {
    public let renewed: Int
    public let failed: Int
    public let expiredKeys: [String]

    public init(renewed: Int, failed: Int, expiredKeys: [String]) {
        self.renewed = renewed
        self.failed = failed
        self.expiredKeys = expiredKeys
    }
}
