import Combine
import Foundation
@preconcurrency import XMTPiOS

// swiftlint:disable implicitly_unwrapped_optional

extension PrivateKey {
    public var walletAddress: String {
        let publicKey = publicKey.secp256K1Uncompressed.bytes
        let publicKeyData =
        publicKey.count == 64 ? publicKey : publicKey[1..<publicKey.count]

        let hash = publicKeyData.sha3(.keccak256)
        let address = hash.subdata(in: 12..<hash.count)
        return "0x" + address.toHex.lowercased()
    }
}

struct MockAuthResult: AuthServiceResultType, AuthServiceRegisteredResultType, Codable {
    var inbox: any AuthServiceInboxType {
        AuthServiceInbox(
            providerId: id,
            signingKey: privateKey,
            databaseKey: databaseKey
        )
    }

    var profile: Profile
    var id: String
    let privateKey: PrivateKey!

    var inboxes: [any AuthServiceInboxType] {
        [inbox]
    }

    var displayName: String? {
        profile.name
    }

    var signingKey: any SigningKey {
        privateKey
    }

    var databaseKey: Data {
        Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    var chainId: Int64? {
        nil
    }

    var walletAddress: String? {
        privateKey.walletAddress
    }

    enum CodingKeys: String, CodingKey {
        case id, name, privateKeyData
    }

    init(name: String) {
        self.id = UUID().uuidString
        self.profile = .mock(name: name)
        self.privateKey = try? PrivateKey.generate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        self.profile = .mock(name: name)
        let privateKeyData = try container.decode(Data.self, forKey: .privateKeyData)
        self.privateKey = try PrivateKey(privateKeyData)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profile.name, forKey: .name)
        try container.encode(privateKey.secp256K1.bytes, forKey: .privateKeyData)
    }

    func sign(message: String) async throws -> Data? {
        return try await privateKey.sign(message).rawData
    }
}

class MockAuthService: LocalAuthServiceProtocol {
    func inbox(for inboxId: String) throws -> (any AuthServiceInboxType)? {
        nil
    }

    var accountsService: (any AuthAccountsServiceProtocol)? {
        nil
    }

    private let persist: Bool
    private let keychain: any KeychainServiceProtocol = KeychainService()
    private var _currentUser: MockAuthResult?
    private static let mockUserAccount: String = "mock-user"

    var currentUser: MockAuthResult? {
        _currentUser
    }

    var state: AuthServiceState {
        authStateSubject.value
    }

    var authStatePublisher: AnyPublisher<AuthServiceState, Never> {
        return authStateSubject.eraseToAnyPublisher()
    }

    private var authStateSubject: CurrentValueSubject<AuthServiceState, Never> = .init(.unknown)

    init(persist: Bool = false) {
        self.persist = persist
        authStateSubject.send(.unauthorized)
    }

    func prepare() throws {
    }

    func signIn() async throws {
        guard let mockUser = try getCurrentUser() else {
            return
        }
        _currentUser = mockUser
        authStateSubject.send(.authorized(mockUser))
    }

    func register(displayName: String) async throws {
        let mockAuthResult = MockAuthResult(name: displayName)
        if persist {
            let encoder = JSONEncoder()
            let data = try encoder.encode(mockAuthResult)
            try keychain.saveData(data, account: Self.mockUserAccount)
        }
        _currentUser = mockAuthResult
        authStateSubject.send(.registered(mockAuthResult))
    }

    func register() throws -> any AuthServiceRegisteredResultType {
        let mockAuthResult = MockAuthResult(name: "")
        if persist {
            let encoder = JSONEncoder()
            let data = try encoder.encode(mockAuthResult)
            try keychain.saveData(data, account: Self.mockUserAccount)
        }
        _currentUser = mockAuthResult
        authStateSubject.send(.registered(mockAuthResult))
        return mockAuthResult
    }

    func deleteAll() throws {
        try keychain.delete(account: Self.mockUserAccount)
        _currentUser = nil
    }

    func deleteAccount(with providerId: String) throws {
        try keychain.delete(account: Self.mockUserAccount)
        _currentUser = nil
    }

    func signOut() async throws {
        if persist {
            try keychain.delete(account: Self.mockUserAccount)
        }
        _currentUser = nil
        authStateSubject.send(.unauthorized)
    }

    func save(inboxId: String, for providerId: String) throws {
    }

    func saveProviderIdMapping(providerId: String, for inboxId: String) throws {
    }

    func inboxId(for providerId: String) throws -> String {
        return UUID().uuidString
    }

    private func getCurrentUser() throws -> MockAuthResult? {
        guard persist else { return nil }
        guard let mockUserData = try keychain.retrieveData(account: Self.mockUserAccount) else {
            authStateSubject.send(.unauthorized)
            return nil
        }
        let jsonDecoder = JSONDecoder()
        let mockAuthResult = try jsonDecoder.decode(MockAuthResult.self,
                                                    from: mockUserData)
        return mockAuthResult
    }
}

// swiftlint:enable implicitly_unwrapped_optional
