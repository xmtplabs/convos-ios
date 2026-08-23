import Darwin
import Foundation

public protocol WebhookHostResolving: Sendable {
    func resolvedAddresses(forHost host: String) throws -> [String]
}

public struct SystemWebhookHostResolver: WebhookHostResolving {
    public init() {}

    public func resolvedAddresses(forHost host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { hostPointer in
            getaddrinfo(hostPointer, nil, &hints, &result)
        }
        guard status == 0, let result else {
            throw AgentRelayError.validation("Webhook host could not be resolved.")
        }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let info = current?.pointee {
            if let address = stringAddress(from: info), !addresses.contains(address) {
                addresses.append(address)
            }
            current = info.ai_next
        }
        return addresses
    }

    private func stringAddress(from info: addrinfo) -> String? {
        guard let address = info.ai_addr else { return nil }

        switch info.ai_family {
        case AF_INET:
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                pointer.pointee.sin_addr
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        case AF_INET6:
            var ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                pointer.pointee.sin6_addr
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        default:
            return nil
        }
    }
}

/// Save-time validation of a webhook URL: https, host present, no userinfo,
/// and no loopback, link-local, private, unsafe IPv4-mapped, integer or hex
/// IPv4, or `.local` host. In the `.local` environment only, exact `127.0.0.1`
/// and `localhost` are accepted over http or https so the fake provider can
/// be reached from a simulator.
public struct WebhookURLValidator: Sendable {
    private let environment: AppEnvironment
    private let resolver: any WebhookHostResolving

    public init(
        environment: AppEnvironment,
        resolver: any WebhookHostResolving = SystemWebhookHostResolver()
    ) {
        self.environment = environment
        self.resolver = resolver
    }

    /// Returns the parsed URL or throws `AgentRelayError.validation`.
    public func validate(_ string: String) throws -> URL {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              let hostValue = components.host,
              !hostValue.isEmpty,
              let url = components.url else {
            throw AgentRelayError.validation("Enter a complete webhook URL with a host.")
        }
        guard components.user == nil, components.password == nil else {
            throw AgentRelayError.validation("Webhook URLs cannot include a username or password.")
        }

        let lowercasedHost = hostValue.lowercased()
        var host: String
        if lowercasedHost.hasPrefix("["), lowercasedHost.hasSuffix("]") {
            host = String(lowercasedHost.dropFirst().dropLast())
        } else {
            host = lowercasedHost
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else {
            throw AgentRelayError.validation("Enter a complete webhook URL with a host.")
        }
        if allowsLocalLoopback(host: host) {
            guard scheme == "http" || scheme == "https" else {
                throw AgentRelayError.validation("Local webhook URLs must use HTTP or HTTPS.")
            }
            return url
        }

        guard scheme == "https" else {
            throw AgentRelayError.validation("Webhook URLs must use HTTPS.")
        }
        guard host != "localhost" else {
            throw AgentRelayError.validation("Webhook URLs cannot use localhost.")
        }
        guard host != "local", !host.hasSuffix(".local") else {
            throw AgentRelayError.validation("Webhook URLs cannot use local network hostnames.")
        }
        guard !isObfuscatedIPv4(host) else {
            throw AgentRelayError.validation("Webhook URLs cannot use encoded numeric IP addresses.")
        }
        guard !isBlockedIPv4(host), !isBlockedIPv6(host) else {
            throw AgentRelayError.validation("Webhook URLs cannot use private or local IP addresses.")
        }
        guard !isLiteralIPAddress(host) else { return url }

        // This closes validation-time DNS rebinding for hosts resolving to blocked addresses.
        // It does not protect against DNS changing before the later request; address pinning is a follow-up.
        let resolvedAddresses = try resolver.resolvedAddresses(forHost: host)
        guard !resolvedAddresses.contains(where: { isBlockedIPv4($0) || isBlockedIPv6($0) }) else {
            throw AgentRelayError.validation("Webhook hosts cannot resolve to private or local IP addresses.")
        }
        return url
    }

    private func allowsLocalLoopback(host: String) -> Bool {
        guard case .local = environment else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    private func isObfuscatedIPv4(_ host: String) -> Bool {
        let lowercaseHost = host.lowercased()
        if lowercaseHost.hasPrefix("0x") {
            return lowercaseHost.dropFirst(2).allSatisfy(\.isHexDigit)
        }
        if lowercaseHost.allSatisfy(\.isNumber) {
            return true
        }

        let components = lowercaseHost.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count < 4 else { return false }
        return components.allSatisfy { component in
            component.allSatisfy(\.isNumber)
        }
    }

    private func isBlockedIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }

        let value: UInt32 = UInt32(bigEndian: address.s_addr)
        return Constant.blockedIPv4Networks.contains { network in
            matchesIPv4(value, network: network.network, prefixLength: network.prefixLength)
        }
    }

    private func isBlockedIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }

        let bytes: [UInt8] = withUnsafeBytes(of: &address) { Array($0) }
        if matchesIPv6(bytes, network: Constant.ipv4MappedPrefix, prefixLength: 96) {
            var mappedAddress = in_addr()
            withUnsafeMutableBytes(of: &mappedAddress) { destination in
                destination.copyBytes(from: bytes.suffix(4))
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &mappedAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return true }
            return isBlockedIPv4(String(cString: buffer))
        }
        return Constant.blockedIPv6Networks.contains { network in
            matchesIPv6(bytes, network: network.network, prefixLength: network.prefixLength)
        }
    }

    private func matchesIPv4(_ value: UInt32, network: UInt32, prefixLength: UInt8) -> Bool {
        let mask: UInt32 = UInt32.max << (UInt32.bitWidth - Int(prefixLength))
        return value & mask == network & mask
    }

    private func matchesIPv6(_ value: [UInt8], network: [UInt8], prefixLength: Int) -> Bool {
        guard value.count == network.count,
              prefixLength >= 0,
              prefixLength <= value.count * UInt8.bitWidth else {
            return false
        }
        let completeByteCount: Int = prefixLength / UInt8.bitWidth
        guard value.prefix(completeByteCount).elementsEqual(network.prefix(completeByteCount)) else { return false }

        let remainingBitCount: Int = prefixLength % UInt8.bitWidth
        guard remainingBitCount > 0 else { return true }
        let mask: UInt8 = UInt8.max << (UInt8.bitWidth - remainingBitCount)
        return value[completeByteCount] & mask == network[completeByteCount] & mask
    }

    private func isLiteralIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }

    private enum Constant {
        static let blockedIPv4Networks: [(network: UInt32, prefixLength: UInt8)] = [
            (0x0000_0000, 8), // 0.0.0.0/8
            (0x0a00_0000, 8), // 10.0.0.0/8
            (0x6440_0000, 10), // 100.64.0.0/10
            (0x7f00_0000, 8), // 127.0.0.0/8
            (0xa9fe_0000, 16), // 169.254.0.0/16
            (0xac10_0000, 12), // 172.16.0.0/12
            (0xc000_0000, 24), // 192.0.0.0/24
            (0xc000_0200, 24), // 192.0.2.0/24
            (0xc058_6300, 24), // 192.88.99.0/24
            (0xc0a8_0000, 16), // 192.168.0.0/16
            (0xc612_0000, 15), // 198.18.0.0/15
            (0xc633_6400, 24), // 198.51.100.0/24
            (0xcb00_7100, 24), // 203.0.113.0/24
            (0xe000_0000, 4), // 224.0.0.0/4
            (0xf000_0000, 4), // 240.0.0.0/4
            (0xffff_ffff, 32), // 255.255.255.255/32
        ]
        static let blockedIPv6Networks: [(network: [UInt8], prefixLength: Int)] = [
            ([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 128), // ::/128
            ([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01], 128), // ::1/128
            ([0x00, 0x64, 0xff, 0x9b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 96), // 64:ff9b::/96
            ([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 64), // 100::/64
            ([0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 32), // 2001:db8::/32
            ([0xfc, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 7), // fc00::/7
            ([0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 10), // fe80::/10
            ([0xfe, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 10), // fec0::/10
            ([0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 8), // ff00::/8
        ]
        static let ipv4MappedPrefix: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        ]
    }
}
