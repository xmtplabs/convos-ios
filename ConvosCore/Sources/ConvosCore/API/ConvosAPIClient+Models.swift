import Foundation

struct EmptyResponse: Decodable {}

public enum ConvosAPI {
    public struct FetchJwtResponse: Codable {
        public let token: String
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
}
