import Foundation

/// Static `ActionSchema` values published by `HealthDataSink`.
///
/// `log_*` actions are mapped to `.writeCreate` since they append a new sample.
/// `fetch_*` actions are mapped to `.read` so invocation gating uses the conversation's
/// read grant instead of a write verb. Updating or deleting existing samples is out of
/// scope for v1.
public enum HealthActionSchemas {
    public static let logWater: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "log_water",
        capability: .writeCreate,
        summary: "Log a water intake sample (dietary water).",
        inputs: [
            ActionParameter(name: "quantity", type: .double, description: "Volume value.", isRequired: true),
            ActionParameter(name: "unit", type: .enumValue(allowed: ["oz", "mL", "L"]), description: "Volume unit.", isRequired: true),
            ActionParameter(name: "date", type: .iso8601DateTime, description: "Sample time (RFC 3339 with offset). Defaults to now.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "sampleId", type: .string, description: "HealthKit sample UUID.", isRequired: true),
        ]
    )

    public static let logCaffeine: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "log_caffeine",
        capability: .writeCreate,
        summary: "Log a caffeine intake sample.",
        inputs: [
            ActionParameter(name: "milligrams", type: .double, description: "Caffeine dose in mg.", isRequired: true),
            ActionParameter(name: "date", type: .iso8601DateTime, description: "Sample time. Defaults to now.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "sampleId", type: .string, description: "HealthKit sample UUID.", isRequired: true),
        ]
    )

    public static let logMindfulMinutes: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "log_mindful_minutes",
        capability: .writeCreate,
        summary: "Log a mindful session with a start and end time.",
        inputs: [
            ActionParameter(name: "startDate", type: .iso8601DateTime, description: "Session start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "endDate", type: .iso8601DateTime, description: "Session end (RFC 3339 with offset).", isRequired: true),
        ],
        outputs: [
            ActionParameter(name: "sampleId", type: .string, description: "HealthKit sample UUID.", isRequired: true),
        ]
    )

    public static let fetchSummaryLast24Hours: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "fetch_summary_last_24h",
        capability: .read,
        summary: "Fetch a read-only health summary for the last 24 hours.",
        inputs: [],
        outputs: [
            ActionParameter(name: "summary", type: .string, description: "Human-readable summary of the window.", isRequired: true),
            ActionParameter(name: "sampleCount", type: .int, description: "Number of mapped samples in the window.", isRequired: true),
            ActionParameter(name: "rangeStart", type: .iso8601DateTime, description: "Window start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "rangeEnd", type: .iso8601DateTime, description: "Window end (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "payloadJson", type: .string, description: "Full HealthPayload JSON string for callers that need richer structured data.", isRequired: true),
        ]
    )

    public static let fetchSamples: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "fetch_samples",
        capability: .read,
        summary: "Fetch read-only health samples for an explicit date range.",
        inputs: [
            ActionParameter(name: "startDate", type: .iso8601DateTime, description: "Window start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "endDate", type: .iso8601DateTime, description: "Window end (RFC 3339 with offset). Must be later than startDate.", isRequired: true),
        ],
        outputs: [
            ActionParameter(name: "summary", type: .string, description: "Human-readable summary of the window.", isRequired: true),
            ActionParameter(name: "sampleCount", type: .int, description: "Number of mapped samples in the window.", isRequired: true),
            ActionParameter(name: "rangeStart", type: .iso8601DateTime, description: "Window start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "rangeEnd", type: .iso8601DateTime, description: "Window end (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "payloadJson", type: .string, description: "Full HealthPayload JSON string for callers that need richer structured data.", isRequired: true),
        ]
    )

    public static let all: [ActionSchema] = [
        logWater,
        logCaffeine,
        logMindfulMinutes,
        fetchSummaryLast24Hours,
        fetchSamples,
    ]
}
