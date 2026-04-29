@testable import ConvosConnections
import Testing

@Suite("Health action schemas")
struct HealthActionSchemasTests {
    @Test("publishes three actions")
    func publishesThreeActions() {
        let schemas = HealthActionSchemas.all
        #expect(schemas.count == 3)
        #expect(Set(schemas.map(\.actionName)) == ["log_water", "log_caffeine", "log_mindful_minutes"])
    }

    @Test("every action is writeCreate")
    func capabilities() {
        #expect(HealthActionSchemas.all.allSatisfy { $0.capability == .writeCreate })
    }

    @Test("log_water requires quantity + unit")
    func waterRequirements() {
        let required = HealthActionSchemas.logWater.inputs.filter(\.isRequired).map(\.name)
        #expect(Set(required) == ["quantity", "unit"])
    }

    @Test("HealthDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = HealthDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == HealthActionSchemas.all)
    }
}
