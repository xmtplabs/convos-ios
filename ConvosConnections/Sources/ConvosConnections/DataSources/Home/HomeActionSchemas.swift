import Foundation

/// Static `ActionSchema` values published by `HomeKitDataSink`.
public enum HomeActionSchemas {
    public static let runScene: ActionSchema = ActionSchema(
        kind: .homeKit,
        actionName: "run_scene",
        capability: .writeCreate,
        summary: "Execute a HomeKit scene (action set).",
        inputs: [
            ActionParameter(name: "homeId", type: .string, description: "Home identifier. If omitted, uses the primary home.", isRequired: false),
            ActionParameter(name: "sceneId", type: .string, description: "Scene (HMActionSet) identifier. Takes precedence over sceneName.", isRequired: false),
            ActionParameter(name: "sceneName", type: .string, description: "Scene name. Collisions return executionFailed.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "sceneId", type: .string, description: "Executed scene identifier.", isRequired: true),
        ]
    )

    public static let setCharacteristicValue: ActionSchema = ActionSchema(
        kind: .homeKit,
        actionName: "set_characteristic_value",
        capability: .writeUpdate,
        summary: "Write a value to a specific accessory characteristic (e.g. turn a light on/off).",
        inputs: [
            ActionParameter(name: "homeId", type: .string, description: "Home identifier. If omitted, uses the primary home.", isRequired: false),
            ActionParameter(name: "accessoryId", type: .string, description: "Accessory identifier.", isRequired: true),
            ActionParameter(name: "characteristicType", type: .string, description: "HomeKit characteristic type UUID or short name ('power', 'brightness', 'targetTemperature').", isRequired: true),
            ActionParameter(name: "value", type: .string, description: "Desired value. Coerced based on the characteristic's metadata format.", isRequired: true),
        ],
        outputs: [
            ActionParameter(name: "accessoryId", type: .string, description: "Accessory identifier.", isRequired: true),
            ActionParameter(name: "characteristicId", type: .string, description: "Resolved characteristic identifier.", isRequired: true),
        ]
    )

    public static let all: [ActionSchema] = [runScene, setCharacteristicValue]
}
