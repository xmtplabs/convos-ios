import Darwin
import Foundation

/// Save-time validation of a webhook URL: https, host present, no userinfo,
/// and no loopback, link-local, private, IPv4-mapped, integer or hex IPv4,
/// or `.local` host. In the `.local` environment only, exact `127.0.0.1`
/// and `localhost` are accepted over http or https so the fake provider can
/// be reached from a simulator.
public struct WebhookURLValidator: Sendable {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
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
        let host: String
        if lowercasedHost.hasPrefix("["), lowercasedHost.hasSuffix("]") {
            host = String(lowercasedHost.dropFirst().dropLast())
        } else {
            host = lowercasedHost
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

        let value = UInt32(bigEndian: address.s_addr)
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)
        if first == 10 || first == 127 || first == 0 {
            return true
        }
        if first == 169, second == 254 {
            return true
        }
        if first == 172, (16 ... 31).contains(second) {
            return true
        }
        return first == 192 && second == 168
    }

    private func isBlockedIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }

        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
        let isMappedIPv4 = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        return isUnspecified || isLoopback || isLinkLocal || isUniqueLocal || isMappedIPv4
    }
}
