import ConvosConnections
@testable import ConvosConnectionsScreenTime
import Testing

@Suite("ScreenTime action schemas")
struct ScreenTimeActionSchemasTests {
    @Test("publishes two actions")
    func publishesTwoActions() {
        let schemas = ScreenTimeActionSchemas.all
        #expect(schemas.count == 2)
        #expect(Set(schemas.map(\.actionName)) == ["apply_selection", "clear_shields"])
    }

    @Test("capabilities")
    func capabilities() {
        #expect(ScreenTimeActionSchemas.applySelection.capability == .writeUpdate)
        #expect(ScreenTimeActionSchemas.clearShields.capability == .writeDelete)
    }

    @Test("apply_selection requires selectionData")
    func applyRequiresData() {
        let required = ScreenTimeActionSchemas.applySelection.inputs.filter(\.isRequired).map(\.name)
        #expect(required == ["selectionData"])
    }

    @Test("ScreenTimeDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = ScreenTimeDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == ScreenTimeActionSchemas.all)
    }
}
