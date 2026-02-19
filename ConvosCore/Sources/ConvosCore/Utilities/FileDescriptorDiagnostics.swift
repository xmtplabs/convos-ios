import Foundation
import os.log

/// Categorized file descriptor info
public struct FDInfo {
    public enum Kind: String {
        case database
        case tcpSocket
        case udpSocket
        case unixSocket
        case pipe
        case file
        case unknown
    }

    public let fd: Int
    public let kind: Kind
    public let detail: String
}

/// Utility for diagnosing file descriptor usage
/// Uses os_log directly to ensure visibility in production builds
public enum FileDescriptorDiagnostics {
    private static let logger: OSLog = OSLog(subsystem: "org.convos.ios", category: "FileDescriptors")

    /// Returns the current number of open file descriptors for this process
    public static func openFileDescriptorCount() -> Int {
        var count = 0
        // File descriptors typically range from 0 to some limit (usually 256-1024 on iOS)
        // We'll check up to 1024 to be safe
        for fd in 0..<1024 where fcntl(Int32(fd), F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// Returns the soft limit for file descriptors
    public static func fileDescriptorLimit() -> (soft: UInt64, hard: UInt64) {
        var limits = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limits) != 0 {
            return (soft: 0, hard: 0)
        }
        return (soft: limits.rlim_cur, hard: limits.rlim_max)
    }

    /// Raises the soft file descriptor limit to the given value (clamped to the hard limit).
    /// Call early in app launch before XMTP clients are created.
    @discardableResult
    public static func raiseSoftLimit(to newLimit: UInt64 = 512) -> Bool {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            os_log(.error, log: logger, "Failed to get current file descriptor limits")
            return false
        }
        let target = min(newLimit, limits.rlim_max)
        let previous = limits.rlim_cur
        if previous >= target {
            os_log(.default, log: logger, "FD soft limit already at %llu (requested %llu)", previous, newLimit)
            return true
        }
        limits.rlim_cur = target
        guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            os_log(.error, log: logger, "Failed to raise FD soft limit to %llu", target)
            return false
        }
        os_log(.default, log: logger, "Raised FD soft limit from %llu to %llu", previous, target)
        return true
    }

    /// Logs current file descriptor usage using os_log (visible in production)
    public static func logUsage(context: String = "") {
        let count = openFileDescriptorCount()
        let limits = fileDescriptorLimit()
        let prefix = context.isEmpty ? "" : "[\(context)] "
        os_log(.default, log: logger, "%{public}@Open file descriptors: %d / %llu (hard limit: %llu)",
               prefix, count, limits.soft, limits.hard)
    }

    /// Returns categorized details about all open file descriptors
    public static func openFileDescriptorInfo() -> [FDInfo] {
        var results: [FDInfo] = []

        for fd in 0..<1024 {
            guard fcntl(Int32(fd), F_GETFD) != -1 else { continue }

            // Try to get file path first
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(Int32(fd), F_GETPATH, &pathBuffer) != -1 {
                let path = String(cString: pathBuffer)
                let kind: FDInfo.Kind = (path.contains(".db") || path.contains("sqlite")) ? .database : .file
                results.append(FDInfo(fd: fd, kind: kind, detail: path))
                continue
            }

            // Not a file - check if it's a socket
            var sockType: Int32 = 0
            var sockTypeLen = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(Int32(fd), SOL_SOCKET, SO_TYPE, &sockType, &sockTypeLen) == 0 {
                let socketInfo = getSocketInfo(fd: Int32(fd), sockType: sockType)
                results.append(socketInfo)
                continue
            }

            // Check if it's a pipe using fstat
            var statInfo = stat()
            if fstat(Int32(fd), &statInfo) == 0 {
                let mode = statInfo.st_mode & S_IFMT
                if mode == S_IFIFO {
                    results.append(FDInfo(fd: fd, kind: .pipe, detail: "pipe"))
                    continue
                }
            }

            results.append(FDInfo(fd: fd, kind: .unknown, detail: "unknown"))
        }

        return results
    }

    private static func getSocketInfo(fd: Int32, sockType: Int32) -> FDInfo {
        // Determine socket kind
        let kind: FDInfo.Kind
        switch sockType {
        case SOCK_STREAM:
            kind = .tcpSocket
        case SOCK_DGRAM:
            kind = .udpSocket
        default:
            kind = .unixSocket
        }

        // Get local address
        var localAddr = sockaddr_storage()
        var localLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let localResult = withUnsafeMutablePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(fd, sockaddrPtr, &localLen)
            }
        }

        // Get peer address (for connected sockets)
        var peerAddr = sockaddr_storage()
        var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let peerResult = withUnsafeMutablePointer(to: &peerAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getpeername(fd, sockaddrPtr, &peerLen)
            }
        }

        var detail = socketTypeString(sockType)

        if localResult == 0 {
            let localStr = formatSocketAddress(&localAddr)
            detail += " local=\(localStr)"
        }

        if peerResult == 0 {
            let peerStr = formatSocketAddress(&peerAddr)
            detail += " peer=\(peerStr)"
        }

        return FDInfo(fd: Int(fd), kind: kind, detail: detail)
    }

    private static func socketTypeString(_ type: Int32) -> String {
        switch type {
        case SOCK_STREAM: return "TCP"
        case SOCK_DGRAM: return "UDP"
        default: return "SOCK(\(type))"
        }
    }

    private static func formatSocketAddress(_ addr: inout sockaddr_storage) -> String {
        switch Int32(addr.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &addr) { storagePtr in
                storagePtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inPtr in
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addrCopy = inPtr.pointee.sin_addr
                    inet_ntop(AF_INET, &addrCopy, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: ipBuffer)
                    let port = UInt16(bigEndian: inPtr.pointee.sin_port)
                    return "\(ip):\(port)"
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &addr) { storagePtr in
                storagePtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { in6Ptr in
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var addrCopy = in6Ptr.pointee.sin6_addr
                    inet_ntop(AF_INET6, &addrCopy, &ipBuffer, socklen_t(INET6_ADDRSTRLEN))
                    let ip = String(cString: ipBuffer)
                    let port = UInt16(bigEndian: in6Ptr.pointee.sin6_port)
                    return "[\(ip)]:\(port)"
                }
            }
        case AF_UNIX:
            return withUnsafePointer(to: &addr) { storagePtr in
                storagePtr.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { unPtr in
                    var pathTuple = unPtr.pointee.sun_path
                    return withUnsafeBytes(of: &pathTuple) { rawBuffer in
                        guard let baseAddress = rawBuffer.baseAddress else { return "unix" }
                        let cString = baseAddress.assumingMemoryBound(to: CChar.self)
                        let path = String(cString: cString)
                        return path.isEmpty ? "unix" : "unix:\(path)"
                    }
                }
            }
        default:
            return "family(\(addr.ss_family))"
        }
    }

    /// Returns details about open file descriptors (for debugging) - legacy format
    public static func openFileDescriptorDetails() -> [(fd: Int, path: String)] {
        openFileDescriptorInfo().map { ($0.fd, $0.detail) }
    }

    /// Logs detailed breakdown of open file descriptors using os_log (visible in production)
    public static func logDetailedUsage() {
        let infos = openFileDescriptorInfo()
        let limits = fileDescriptorLimit()

        // Group by kind
        var counts: [FDInfo.Kind: Int] = [:]
        for info in infos {
            counts[info.kind, default: 0] += 1
        }

        // Build single report string to avoid interleaving with other logs
        var report = "=== File Descriptor Report ===\n"
        report += "Total open: \(infos.count) / \(limits.soft) (hard: \(limits.hard))\n"
        report += "  Databases: \(counts[.database] ?? 0)\n"
        report += "  TCP sockets: \(counts[.tcpSocket] ?? 0)\n"
        report += "  UDP sockets: \(counts[.udpSocket] ?? 0)\n"
        report += "  Unix sockets: \(counts[.unixSocket] ?? 0)\n"
        report += "  Pipes: \(counts[.pipe] ?? 0)\n"
        report += "  Other files: \(counts[.file] ?? 0)\n"
        report += "  Unknown: \(counts[.unknown] ?? 0)"

        // Add socket details first (usually smaller list)
        let socketInfos = infos.filter { [.tcpSocket, .udpSocket, .unixSocket].contains($0.kind) }
        if !socketInfos.isEmpty {
            report += "\nSockets:"
            for info in socketInfos {
                report += "\n  fd \(info.fd): \(info.detail)"
            }
        }

        // Add database file details
        let dbInfos = infos.filter { $0.kind == .database }
        if !dbInfos.isEmpty {
            report += "\nDatabase files:"
            for info in dbInfos {
                report += "\n  fd \(info.fd): \(info.detail)"
            }
        }

        os_log(.default, log: logger, "%{public}@", report)
    }
}
