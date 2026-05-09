import Foundation

/// Static `ActionSchema` values published by `PhotosDataSink`.
public enum PhotosActionSchemas {
    public static let saveImage: ActionSchema = ActionSchema(
        kind: .photos,
        actionName: "save_image",
        capability: .writeCreate,
        summary: "Save image data to the user's photo library.",
        inputs: [
            ActionParameter(name: "imageData", type: .string, description: "Base64-encoded image bytes (JPEG/PNG/HEIC).", isRequired: true),
            ActionParameter(name: "isFavorite", type: .bool, description: "Mark the saved asset as a favorite.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "assetId", type: .string, description: "Local identifier of the newly-saved asset.", isRequired: true),
        ]
    )

    public static let favoriteAsset: ActionSchema = ActionSchema(
        kind: .photos,
        actionName: "favorite_asset",
        capability: .writeUpdate,
        summary: "Toggle the favorite flag on a photo library asset.",
        inputs: [
            ActionParameter(name: "assetId", type: .string, description: "Local identifier of the asset.", isRequired: true),
            ActionParameter(name: "isFavorite", type: .bool, description: "Desired favorite state.", isRequired: true),
        ],
        outputs: [
            ActionParameter(name: "assetId", type: .string, description: "Updated asset identifier.", isRequired: true),
        ]
    )

    public static let deleteAsset: ActionSchema = ActionSchema(
        kind: .photos,
        actionName: "delete_asset",
        capability: .writeDelete,
        summary: "Delete an asset from the user's photo library (user is prompted by iOS).",
        inputs: [
            ActionParameter(name: "assetId", type: .string, description: "Local identifier of the asset to delete.", isRequired: true),
        ],
        outputs: []
    )

    public static let all: [ActionSchema] = [saveImage, favoriteAsset, deleteAsset]
}
