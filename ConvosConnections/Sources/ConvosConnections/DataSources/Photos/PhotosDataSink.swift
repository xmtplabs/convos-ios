import Foundation
#if canImport(Photos)
@preconcurrency import Photos
#endif

/// Write-side counterpart to `PhotosDataSource`.
///
/// Supports three actions: `save_image` (import Base64 image data), `favorite_asset` (flip
/// the favorite flag), and `delete_asset` (iOS presents the confirmation sheet).
///
/// `save_image` accepts Base64-encoded bytes rather than raw binary because the arguments
/// payload is a JSON-codable dictionary. Agents that want to send real images should
/// Base64-encode them on their side.
public final class PhotosDataSink: DataSink, @unchecked Sendable {
    public let kind: ConnectionKind = .photos

    public init() {}

    public func actionSchemas() async -> [ActionSchema] {
        PhotosActionSchemas.all
    }

    #if canImport(Photos)
    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        PhotosDataSource.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotosDataSource.map(status)
    }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        switch invocation.action.name {
        case PhotosActionSchemas.saveImage.actionName:
            return await saveImage(invocation)
        case PhotosActionSchemas.favoriteAsset.actionName:
            return await favoriteAsset(invocation)
        case PhotosActionSchemas.deleteAsset.actionName:
            return await deleteAsset(invocation)
        default:
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "Photos sink does not know action '\(invocation.action.name)'."
            )
        }
    }

    private func saveImage(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        guard Self.canWrite() else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Photo library write access is not granted.")
        }
        let args = invocation.action.arguments
        guard let base64 = args["imageData"]?.stringValue,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing or invalid 'imageData' (must be Base64).")
        }
        let isFavorite = args["isFavorite"]?.boolValue ?? false

        var placeholderId: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                request.isFavorite = isFavorite
                placeholderId = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }
        guard let assetId = placeholderId else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Save succeeded but no asset identifier was produced.")
        }
        return Self.makeResult(for: invocation, status: .success, result: ["assetId": .string(assetId)])
    }

    private func favoriteAsset(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        guard Self.canWrite() else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Photo library write access is not granted.")
        }
        let args = invocation.action.arguments
        guard let assetId = args["assetId"]?.stringValue else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'assetId'.")
        }
        guard let isFavorite = args["isFavorite"]?.boolValue else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'isFavorite'.")
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Asset not found for id '\(assetId)'.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.isFavorite = isFavorite
            }
        } catch {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }
        return Self.makeResult(for: invocation, status: .success, result: ["assetId": .string(assetId)])
    }

    private func deleteAsset(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        guard Self.canWrite() else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Photo library write access is not granted.")
        }
        let args = invocation.action.arguments
        guard let assetId = args["assetId"]?.stringValue else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'assetId'.")
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard assets.firstObject != nil else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Asset not found for id '\(assetId)'.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }
        return Self.makeResult(for: invocation, status: .success)
    }

    private static func canWrite() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    private static func makeResult(
        for invocation: ConnectionInvocation,
        status: ConnectionInvocationResult.Status,
        errorMessage: String? = nil,
        result: [String: ArgumentValue] = [:]
    ) -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: status,
            result: result,
            errorMessage: errorMessage
        )
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: .photos,
            actionName: invocation.action.name,
            status: .executionFailed,
            errorMessage: "Photos framework not available on this platform."
        )
    }
    #endif
}
