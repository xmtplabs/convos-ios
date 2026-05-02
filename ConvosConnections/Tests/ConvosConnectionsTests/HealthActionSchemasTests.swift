@testable import ConvosConnections
import Testing

@Suite("Health action schemas")
struct HealthActionSchemasTests {
    @Test("publishes the expected action set")
    func publishesExpectedActions() {
        let schemas = HealthActionSchemas.all
        #expect(schemas.count == 7)
        #expect(Set(schemas.map(\.actionName)) == [
            "log_water",
            "log_caffeine",
            "log_mindful_minutes",
            "fetch_summary_last_24h",
            "fetch_samples",
            "subscribe_background_delivery",
            "unsubscribe_background_delivery",
        ])
    }

    @Test("capabilities match read vs write verbs")
    func capabilities() {
        #expect(HealthActionSchemas.logWater.capability == .writeCreate)
        #expect(HealthActionSchemas.logCaffeine.capability == .writeCreate)
        #expect(HealthActionSchemas.logMindfulMinutes.capability == .writeCreate)
        #expect(HealthActionSchemas.fetchSummaryLast24Hours.capability == .read)
        #expect(HealthActionSchemas.fetchSamples.capability == .read)
        #expect(HealthActionSchemas.subscribeBackgroundDelivery.capability == .read)
        #expect(HealthActionSchemas.unsubscribeBackgroundDelivery.capability == .read)
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

    @Test("subscribe_background_delivery requires typeIdentifier + frequency, optional historyDays")
    func subscribeRequirements() {
        let inputs = HealthActionSchemas.subscribeBackgroundDelivery.inputs
        let required = inputs.filter(\.isRequired).map(\.name)
        let optional = inputs.filter { !$0.isRequired }.map(\.name)
        #expect(Set(required) == ["typeIdentifier", "frequency"])
        #expect(Set(optional) == ["historyDays"])
    }

    @Test("subscribe_background_delivery typeIdentifier accepts the supported HealthSampleType values")
    func subscribeTypeIdentifierAllowedValues() {
        let typeIdentifier = HealthActionSchemas.subscribeBackgroundDelivery.inputs
            .first { $0.name == "typeIdentifier" }
        guard case .enumValue(let allowed) = typeIdentifier?.type else {
            Issue.record("typeIdentifier should be an enumValue parameter")
            return
        }
        #expect(Set(allowed) == Set(HealthSampleType.allCases.map(\.rawValue)))
    }

    @Test("subscribe_background_delivery frequency accepts the documented cadences")
    func subscribeFrequencyAllowedValues() {
        let frequency = HealthActionSchemas.subscribeBackgroundDelivery.inputs
            .first { $0.name == "frequency" }
        guard case .enumValue(let allowed) = frequency?.type else {
            Issue.record("frequency should be an enumValue parameter")
            return
        }
        #expect(Set(allowed) == ["immediate", "hourly", "daily", "weekly"])
    }

    @Test("unsubscribe_background_delivery requires typeIdentifier")
    func unsubscribeRequirements() {
        let required = HealthActionSchemas.unsubscribeBackgroundDelivery.inputs.filter(\.isRequired).map(\.name)
        #expect(Set(required) == ["typeIdentifier"])
    }

    @Test("HealthDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = HealthDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == HealthActionSchemas.all)
    }
}
