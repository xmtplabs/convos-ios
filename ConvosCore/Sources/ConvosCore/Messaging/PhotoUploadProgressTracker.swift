import Foundation
import Observation

public enum PhotoUploadStage: Sendable, Equatable {
    case preparing
    case uploading
    case publishing
    case completed
    case failed

    public var label: String {
        switch self {
        case .preparing: "Preparing..."
        case .uploading: "Uploading..."
        case .publishing: "Sending..."
        case .completed: ""
        case .failed: "Failed"
        }
    }

    public var isCompleted: Bool {
        self == .completed
    }

    public var isFailed: Bool {
        self == .failed
    }

    public var isInProgress: Bool {
        switch self {
        case .preparing, .uploading, .publishing:
            true
        case .completed, .failed:
            false
        }
    }
}

public struct PhotoUploadProgress: Sendable, Equatable {
    public let stage: PhotoUploadStage
    public let percentage: Double?

    public init(stage: PhotoUploadStage, percentage: Double? = nil) {
        self.stage = stage
        self.percentage = percentage
    }
}

@Observable
public final class PhotoUploadProgressTracker: @unchecked Sendable {
    public static let shared: PhotoUploadProgressTracker = PhotoUploadProgressTracker()

    private var progressEntries: [String: PhotoUploadProgress] = [:]
    private let lock: NSLock = NSLock()

    private init() {}

    public func setStage(_ stage: PhotoUploadStage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        progressEntries[key] = PhotoUploadProgress(stage: stage, percentage: nil)
    }

    public func setProgress(stage: PhotoUploadStage, percentage: Double?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        progressEntries[key] = PhotoUploadProgress(stage: stage, percentage: percentage)
    }

    public func stage(for key: String) -> PhotoUploadStage? {
        lock.lock()
        defer { lock.unlock() }
        return progressEntries[key]?.stage
    }

    public func progress(for key: String) -> PhotoUploadProgress? {
        lock.lock()
        defer { lock.unlock() }
        return progressEntries[key]
    }

    public func clear(key: String) {
        lock.lock()
        defer { lock.unlock() }
        progressEntries.removeValue(forKey: key)
    }
}
