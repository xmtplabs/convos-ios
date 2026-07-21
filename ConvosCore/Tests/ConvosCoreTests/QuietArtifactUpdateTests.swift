import Foundation
import Testing
@testable import ConvosCore

struct QuietArtifactUpdateTests {
    @Test("recognizes the sentinel before the extension")
    func recognizesSentinel() {
        #expect(QuietArtifactUpdate.isQuiet(filename: "notes~quiet.html"))
        #expect(!QuietArtifactUpdate.isQuiet(filename: "notes.html"))
        #expect(!QuietArtifactUpdate.isQuiet(filename: nil))
    }

    @Test("a filename merely containing the sentinel is not quiet")
    func sentinelMustBeTerminal() {
        // The sentinel marks the end of the stem; anywhere else it is just
        // part of a name the agent chose.
        #expect(!QuietArtifactUpdate.isQuiet(filename: "~quiet-notes.html"))
        #expect(!QuietArtifactUpdate.isQuiet(filename: "notes~quiet-2.html"))
    }

    @Test("strips the sentinel back to the artifact's real name")
    func stripsToCanonical() {
        #expect(QuietArtifactUpdate.canonicalFilename("notes~quiet.html") == "notes.html")
        #expect(QuietArtifactUpdate.canonicalFilename("trip.plan~quiet.html") == "trip.plan.html")
    }

    @Test("leaves ordinary filenames untouched")
    func passesThroughOrdinary() {
        #expect(QuietArtifactUpdate.canonicalFilename("notes.html") == "notes.html")
        #expect(QuietArtifactUpdate.canonicalFilename(nil) == nil)
    }

    @Test("a quiet update and its loud original share one identity")
    func quietAndLoudDedupeTogether() {
        // This is what makes the update supersede rather than accumulate in
        // Files & Links and the Things view.
        #expect(
            QuietArtifactUpdate.canonicalFilename("notes~quiet.html")
                == QuietArtifactUpdate.canonicalFilename("notes.html")
        )
    }

    @Test("handles an extensionless name")
    func handlesNoExtension() {
        #expect(QuietArtifactUpdate.canonicalFilename("notes~quiet") == "notes")
    }
}
