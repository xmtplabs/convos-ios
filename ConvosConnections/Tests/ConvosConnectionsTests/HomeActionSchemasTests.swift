@testable import ConvosConnections
import Testing

@Suite("HomeKit action schemas")
struct HomeActionSchemasTests {
    @Test("publishes two actions")
    func publishesTwoActions() {
        let schemas = HomeActionSchemas.all
        #expect(schemas.count == 2)
        let names = Set(schemas.map(\.actionName))
        #expect(names == ["run_scene", "set_characteristic_value"])
    }

    @Test("capabilities are writeCreate and writeUpdate")
    func capabilities() {
        #expect(HomeActionSchemas.runScene.capability == .writeCreate)
        #expect(HomeActionSchemas.setCharacteristicValue.capability == .writeUpdate)
    }

    @Test("set_characteristic requires accessoryId + characteristicType + value")
    func requiredInputs() {
        let inputs = HomeActionSchemas.setCharacteristicValue.inputs
        let required = inputs.filter(\.isRequired).map(\.name)
        #expect(Set(required) == ["accessoryId", "characteristicType", "value"])
    }

    @Test("HomeKitDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = HomeKitDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == HomeActionSchemas.all)
    }
}
