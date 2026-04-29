import Foundation

/// Static `ActionSchema` values published by `HealthDataSink`.
///
/// All three `log_*` actions are mapped to `.writeCreate` since they append a new sample.
/// Updating or deleting existing samples is out of scope for v1.
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

    public static let all: [ActionSchema] = [logWater, logCaffeine, logMindfulMinutes]
}
