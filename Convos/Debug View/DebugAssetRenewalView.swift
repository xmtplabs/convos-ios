import ConvosCore
import SwiftUI

struct DebugAssetRenewalView: View {
    let environment: AppEnvironment

    @State private var assets: [RenewableAsset] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var renewalAlertMessage: String?
    @State private var showingRenewalAlert: Bool = false
    @State private var refreshTrigger: Bool = false

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
                        AssetRow(asset: asset, environment: environment) { message in
                            renewalAlertMessage = message
                            showingRenewalAlert = true
                            refreshTrigger.toggle()
                        }
                    }
                }

                Section(header: Text("Group Images (\(groupImages.count))")) {
                    ForEach(groupImages, id: \.url) { asset in
                        AssetRow(asset: asset, environment: environment) { message in
                            renewalAlertMessage = message
                            showingRenewalAlert = true
                            refreshTrigger.toggle()
                        }
                    }
                }
            }
        }
        .navigationTitle("Renewable Assets")
        .task(id: refreshTrigger) {
            await loadAssets()
        }
        .alert("Asset Renewal", isPresented: $showingRenewalAlert, presenting: renewalAlertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
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
            let env = environment
            let loadedAssets = try await Task.detached {
                let dbManager = DatabaseManager(environment: env)
                let collector = AssetRenewalURLCollector(databaseReader: dbManager.dbReader)
                return try collector.collectRenewableAssets()
            }.value
            guard !Task.isCancelled else { return }
            assets = loadedAssets
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Failed to load assets: \(error.localizedDescription)"
        }

        guard !Task.isCancelled else { return }
        isLoading = false
    }
}

private struct AssetRow: View {
    let asset: RenewableAsset
    let environment: AppEnvironment
    let onRenewalComplete: (String) -> Void

    @State private var isRenewing: Bool = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(assetTypeLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if isRenewing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            Text(asset.key ?? "No key")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let key = asset.key {
                HStack(spacing: 8) {
                    if let lastDate = AssetRenewalManager.lastRenewalDate(for: key) {
                        Text("Last: \(Self.dateFormatter.string(from: lastDate))")
                    } else {
                        Text("Last: Never")
                    }

                    Text("•")

                    if let dueDate = AssetRenewalManager.nextRenewalDate(for: key) {
                        let isPastDue = dueDate < Date()
                        Text("Due: \(Self.dateFormatter.string(from: dueDate))")
                            .foregroundStyle(isPastDue ? .orange : .colorTextSecondary)
                    } else {
                        Text("Due: Now")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                if let key = asset.key {
                    UIPasteboard.general.string = key
                }
            } label: {
                Label("Copy Key", systemImage: "doc.on.doc")
            }
            .disabled(asset.key == nil)

            Button {
                Task { await renewSingleAsset() }
            } label: {
                Label("Renew Asset", systemImage: "arrow.clockwise")
            }
            .disabled(isRenewing || asset.key == nil)
        }
    }

    private var assetTypeLabel: String {
        switch asset {
        case let .profileAvatar(_, conversationId, _):
            return "Profile (\(conversationId.prefix(8))…)"
        case let .groupImage(_, conversationId):
            return "Group (\(conversationId.prefix(8))…)"
        }
    }

    private func renewSingleAsset() async {
        guard !isRenewing else { return }
        isRenewing = true

        let env = environment
        let assetToRenew = asset
        let result = await Task.detached {
            let dbManager = DatabaseManager(environment: env)
            let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: dbManager.dbWriter)
            let renewalManager = AssetRenewalManager(
                databaseReader: dbManager.dbReader,
                apiClient: ConvosAPIClientFactory.client(environment: env),
                recoveryHandler: recoveryHandler
            )
            return await renewalManager.renewSingleAsset(assetToRenew)
        }.value

        isRenewing = false

        if let result {
            if result.renewed > 0 {
                onRenewalComplete("Asset renewed successfully")
            } else if !result.expiredKeys.isEmpty {
                onRenewalComplete("Asset expired and was cleared")
            } else {
                onRenewalComplete("No renewal needed")
            }
        } else {
            onRenewalComplete("Renewal failed. Check logs.")
        }
    }
}

#Preview {
    NavigationStack {
        DebugAssetRenewalView(environment: .tests)
    }
}
