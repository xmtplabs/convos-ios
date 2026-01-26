import ConvosCore
import SwiftUI

struct DebugAssetRenewalView: View {
    let environment: AppEnvironment

    @State private var assets: [RenewableAsset] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Text("Loading assets…")
                        Spacer()
                        ProgressView()
                    }
                }
            } else if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else if assets.isEmpty {
                Section {
                    Text("No renewable assets found")
                        .foregroundStyle(.colorTextSecondary)
                }
            } else {
                Section(header: Text("Profile Avatars (\(profileAvatars.count))")) {
                    ForEach(profileAvatars, id: \.url) { asset in
                        AssetRow(asset: asset)
                    }
                }

                Section(header: Text("Group Images (\(groupImages.count))")) {
                    ForEach(groupImages, id: \.url) { asset in
                        AssetRow(asset: asset)
                    }
                }
            }
        }
        .navigationTitle("Renewable Assets")
        .task {
            await loadAssets()
        }
    }

    private var profileAvatars: [RenewableAsset] {
        assets.filter {
            if case .profileAvatar = $0 { return true }
            return false
        }
    }

    private var groupImages: [RenewableAsset] {
        assets.filter {
            if case .groupImage = $0 { return true }
            return false
        }
    }

    private func loadAssets() async {
        isLoading = true
        errorMessage = nil

        do {
            let dbManager = DatabaseManager(environment: environment)
            let collector = AssetRenewalURLCollector(databaseReader: dbManager.dbReader)
            assets = try collector.collectRenewableAssets()
        } catch {
            errorMessage = "Failed to load assets: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

private struct AssetRow: View {
    let asset: RenewableAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(assetTypeLabel)
                .font(.subheadline)
                .fontWeight(.medium)

            Text(asset.key ?? "No key")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }

    private var assetTypeLabel: String {
        switch asset {
        case let .profileAvatar(_, conversationId, _):
            return "Profile (\(conversationId.prefix(8))…)"
        case let .groupImage(_, conversationId):
            return "Group (\(conversationId.prefix(8))…)"
        }
    }
}

#Preview {
    NavigationStack {
        DebugAssetRenewalView(environment: .tests)
    }
}
