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

    public struct AgentJoinRequest: Codable {
        public let slug: String?
        public let conversationId: String?
        public let templateId: String?
        public let options: AgentJoinOptions?

        public init(
            slug: String? = nil,
            conversationId: String? = nil,
            templateId: String? = nil,
            options: AgentJoinOptions? = nil
        ) {
            self.slug = slug
            self.conversationId = conversationId
            self.templateId = templateId
            self.options = options
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

        public init(onboarding: String?) {
            self.onboarding = onboarding
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
