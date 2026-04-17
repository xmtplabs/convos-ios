@testable import ConvosConnections
import Testing

@Suite("Music action schemas")
struct MusicActionSchemasTests {
    @Test("publishes five actions")
    func publishesFiveActions() {
        let schemas = MusicActionSchemas.all
        #expect(schemas.count == 5)
        #expect(Set(schemas.map(\.actionName)) == [
            "play", "pause", "skip_to_next", "skip_to_previous", "queue_store_items",
        ])
    }

    @Test("transport controls are writeUpdate")
    func transportCapabilities() {
        #expect(MusicActionSchemas.play.capability == .writeUpdate)
        #expect(MusicActionSchemas.pause.capability == .writeUpdate)
        #expect(MusicActionSchemas.skipToNext.capability == .writeUpdate)
        #expect(MusicActionSchemas.skipToPrevious.capability == .writeUpdate)
    }

    @Test("queue_store_items is writeCreate and requires storeIds")
    func queueRequirements() {
        #expect(MusicActionSchemas.queueStoreItems.capability == .writeCreate)
        let required = MusicActionSchemas.queueStoreItems.inputs.filter(\.isRequired).map(\.name)
        #expect(required == ["storeIds"])
    }

    @Test("MusicDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = MusicDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == MusicActionSchemas.all)
    }
}
