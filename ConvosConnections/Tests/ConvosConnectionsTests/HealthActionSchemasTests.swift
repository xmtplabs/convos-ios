@testable import ConvosConnections
import Testing

@Suite("Health action schemas")
struct HealthActionSchemasTests {
    @Test("publishes five actions")
    func publishesFiveActions() {
        let schemas = HealthActionSchemas.all
        #expect(schemas.count == 5)
        #expect(Set(schemas.map(\.actionName)) == [
            "log_water",
            "log_caffeine",
            "log_mindful_minutes",
            "fetch_summary_last_24h",
            "fetch_samples",
        ])
    }

    @Test("capabilities match read vs write verbs")
    func capabilities() {
        #expect(HealthActionSchemas.logWater.capability == .writeCreate)
        #expect(HealthActionSchemas.logCaffeine.capability == .writeCreate)
        #expect(HealthActionSchemas.logMindfulMinutes.capability == .writeCreate)
        #expect(HealthActionSchemas.fetchSummaryLast24Hours.capability == .read)
        #expect(HealthActionSchemas.fetchSamples.capability == .read)
    }

    @Test("log_water requires quantity + unit")
    func waterRequirements() {
        let required = HealthActionSchemas.logWater.inputs.filter(\.isRequired).map(\.name)
        #expect(Set(required) == ["quantity", "unit"])
    }

    @Test("fetch_samples requires startDate + endDate")
    func fetchSamplesRequirements() {
        let required = HealthActionSchemas.fetchSamples.inputs.filter(\.isRequired).map(\.name)
        #expect(Set(required) == ["startDate", "endDate"])
    }

    @Test("HealthDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = HealthDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == HealthActionSchemas.all)
    }
}
