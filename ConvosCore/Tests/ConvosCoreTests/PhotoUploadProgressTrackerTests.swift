import Foundation
import Testing
@testable import ConvosCore

@Suite("PhotoUploadProgressTracker Tests")
struct PhotoUploadProgressTrackerTests {
    @Test("Setting progress updates both stage and percentage")
    func testSetProgressUpdatesStageAndPercentage() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setProgress(stage: .uploading, percentage: 0.5, for: key)

        let progress = tracker.progress(for: key)
        #expect(progress?.stage == .uploading)
        #expect(progress?.percentage == 0.5)

        tracker.clear(key: key)
    }

    @Test("Progress percentage defaults to nil when only stage is set")
    func testStageOnlyHasNilPercentage() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setStage(.preparing, for: key)

        let progress = tracker.progress(for: key)
        #expect(progress?.stage == .preparing)
        #expect(progress?.percentage == nil)

        tracker.clear(key: key)
    }

    @Test("Stage accessor maintains backward compatibility")
    func testStageAccessorBackwardCompatibility() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setStage(.uploading, for: key)

        let stage = tracker.stage(for: key)
        #expect(stage == .uploading)

        tracker.clear(key: key)
    }

    @Test("Stage accessor works with progress set via setProgress")
    func testStageAccessorWithSetProgress() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setProgress(stage: .publishing, percentage: 0.75, for: key)

        let stage = tracker.stage(for: key)
        #expect(stage == .publishing)

        tracker.clear(key: key)
    }

    @Test("Clear removes progress entry")
    func testClearRemovesProgress() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setProgress(stage: .uploading, percentage: 0.5, for: key)
        tracker.clear(key: key)

        let progress = tracker.progress(for: key)
        #expect(progress == nil)
    }

    @Test("Progress returns nil for unknown key")
    func testProgressReturnsNilForUnknownKey() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "nonexistent-key-\(UUID().uuidString)"

        let progress = tracker.progress(for: key)
        #expect(progress == nil)
    }

    @Test("PhotoUploadProgress struct is equatable")
    func testPhotoUploadProgressEquatable() {
        let progress1 = PhotoUploadProgress(stage: .uploading, percentage: 0.5)
        let progress2 = PhotoUploadProgress(stage: .uploading, percentage: 0.5)
        let progress3 = PhotoUploadProgress(stage: .uploading, percentage: 0.6)
        let progress4 = PhotoUploadProgress(stage: .preparing, percentage: 0.5)

        #expect(progress1 == progress2)
        #expect(progress1 != progress3)
        #expect(progress1 != progress4)
    }

    @Test("Percentage can be updated for same key")
    func testPercentageCanBeUpdated() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setProgress(stage: .uploading, percentage: 0.25, for: key)
        #expect(tracker.progress(for: key)?.percentage == 0.25)

        tracker.setProgress(stage: .uploading, percentage: 0.75, for: key)
        #expect(tracker.progress(for: key)?.percentage == 0.75)

        tracker.clear(key: key)
    }
}
