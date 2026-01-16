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

@Observable
public final class PhotoUploadProgressTracker: @unchecked Sendable {
    public static let shared: PhotoUploadProgressTracker = PhotoUploadProgressTracker()

    private var stages: [String: PhotoUploadStage] = [:]
    private let lock: NSLock = NSLock()

    private init() {}

    public func setStage(_ stage: PhotoUploadStage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        stages[key] = stage
    }

    public func stage(for key: String) -> PhotoUploadStage? {
        lock.lock()
        defer { lock.unlock() }
        return stages[key]
    }

    public func clear(key: String) {
        lock.lock()
        defer { lock.unlock() }
        stages.removeValue(forKey: key)
    }
}
