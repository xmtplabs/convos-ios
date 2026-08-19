import ConvosComposer
import SwiftUI

/// Demo-only personal context that can be suggested for the current Home and
/// conversation. The production version must be assembled from the signed-in
/// user's private context service and must never publish an item without an
/// explicit, destination-scoped approval.
struct PersonalContextItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case preference = "Preference"
        case memory = "Memory"
        case file = "File"
        case connection = "Connection"
    }

    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let kind: Kind
}

struct PersonalContextBundle: Identifiable, Hashable {
    let id: String
    let title: String
    let reason: String
    let items: [PersonalContextItem]

    static let suggestedForCurrentConvo: PersonalContextBundle = PersonalContextBundle(
        id: "travel-ready",
        title: "Travel details for this convo",
        reason: "Space Abilities noticed this group is planning a trip and found four details that could make the Home more useful.",
        items: [
            PersonalContextItem(
                id: "home-airport",
                title: "Home airport: AUS",
                detail: "Helps with departure timing and flight suggestions",
                symbolName: "airplane.departure",
                kind: .memory
            ),
            PersonalContextItem(
                id: "aisle-seat",
                title: "Aisle seat when possible",
                detail: "A saved travel preference",
                symbolName: "chair.lounge.fill",
                kind: .preference
            ),
            PersonalContextItem(
                id: "calendar-availability",
                title: "Calendar availability",
                detail: "Shares free and busy windows, not private event details",
                symbolName: "calendar",
                kind: .connection
            ),
            PersonalContextItem(
                id: "travel-profile",
                title: "Travel profile.pdf",
                detail: "A personal file saved for trip planning",
                symbolName: "doc.fill",
                kind: .file
            ),
        ]
    )

    static let catalog: [PersonalContextItem] = suggestedForCurrentConvo.items
}

/// Small persistence shim for the clickable prototype. It stores only demo
/// item ids and is intentionally unavailable as a production data contract.
enum PersonalContextPrototypeStore {
    private static let keyPrefix: String = "agent-chat-personal-context-demo."

    static func approvedItemIds(for conversationId: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: keyPrefix + conversationId) ?? [])
    }

    static func save(_ itemIds: Set<String>, for conversationId: String) {
        UserDefaults.standard.set(itemIds.sorted(), forKey: keyPrefix + conversationId)
    }

    static func removeAccess(for conversationId: String) {
        UserDefaults.standard.removeObject(forKey: keyPrefix + conversationId)
    }

    static func items(for conversationId: String) -> [PersonalContextItem] {
        let approvedIds = approvedItemIds(for: conversationId)
        return PersonalContextBundle.catalog.filter { approvedIds.contains($0.id) }
    }
}

struct PersonalContextSuggestionView: View {
    let conversationId: String
    let approvedItemIds: Set<String>
    let onApproved: (PersonalContextBundle) -> Void
    let onRemoved: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var reviewingBundle: PersonalContextBundle?

    private var approvedItems: [PersonalContextItem] {
        PersonalContextBundle.catalog.filter { approvedItemIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                    heading
                    if approvedItems.isEmpty {
                        suggestion
                    } else {
                        currentAccess
                    }
                    privacyBoundary
                    prototypeDisclosure
                }
                .padding(.horizontal, DesignConstants.Spacing.step5x)
                .padding(.top, DesignConstants.Spacing.step6x)
                .padding(.bottom, DesignConstants.Spacing.step12x)
            }
            .background(.colorBackgroundSurfaceless)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(item: $reviewingBundle) { bundle in
                PersonalContextApprovalView(
                    bundle: bundle,
                    onApproved: {
                        onApproved(bundle)
                        dismiss()
                    }
                )
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(width: 76, height: 76)
                .background(.colorLava, in: .circle)
                .accessibilityHidden(true)

            Text(approvedItems.isEmpty ? "Your context is ready when it helps" : "My context in this convo")
                .font(.system(size: 38, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                approvedItems.isEmpty
                    ? "Convos can suggest a small bundle for the current Home or conversation. You decide exactly what the group receives."
                    : "Space Abilities can use only the context you approved below. Everything else stays private."
            )
            .font(.title3)
            .foregroundStyle(.colorTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suggestion: some View {
        let bundle = PersonalContextBundle.suggestedForCurrentConvo
        return VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorLava)
                    .frame(width: 40, height: 40)
                    .background(Color.colorLava.opacity(0.1), in: .circle)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Suggested for this convo")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                    Text(bundle.title)
                        .font(.title2.bold())
                        .foregroundStyle(.colorTextPrimary)
                }
            }

            Text(bundle.reason)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignConstants.Spacing.step3x) {
                contextPreviewStack(bundle.items)
                Text("\(bundle.items.count) items")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                Text("Home + chat")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }

            Button {
                reviewingBundle = bundle
            } label: {
                Text("Review suggested context")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every item and who can use it before anything is shared")
        }
        .padding(DesignConstants.Spacing.step5x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
    }

    private var currentAccess: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            HStack {
                Text("Shared with Space Abilities")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                Text("\(approvedItems.count) items")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(spacing: 0) {
                ForEach(approvedItems) { item in
                    PersonalContextItemRow(item: item, showsKind: true)
                    if item.id != approvedItems.last?.id {
                        Divider()
                    }
                }
            }

            Button("Remove access", role: .destructive) {
                onRemoved()
                dismiss()
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.colorFillSubtle, in: .rect(cornerRadius: 16))
        }
    }

    private var privacyBoundary: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Label("Always available to you", systemImage: "person.fill")
            Label("Never shared without your approval", systemImage: "checkmark.shield.fill")
            Label("Remove group access at any time", systemImage: "arrow.uturn.backward.circle.fill")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.colorTextSecondary)
    }

    private var prototypeDisclosure: some View {
        Label("Clickable prototype — these are illustrative details and no personal data is shared", systemImage: "sparkles")
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func contextPreviewStack(_ items: [PersonalContextItem]) -> some View {
        HStack(spacing: -8) {
            ForEach(items.prefix(4)) { item in
                Image(systemName: item.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 30, height: 30)
                    .background(.colorBackgroundSurfaceless, in: .circle)
                    .overlay { Circle().stroke(.colorBackgroundRaisedSecondary, lineWidth: 2) }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PersonalContextApprovalView: View {
    let bundle: PersonalContextBundle
    let onApproved: () -> Void

    @State private var isApproving: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                heading
                destination
                exactItems
                lastingAccess
                prototypeDisclosure
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.bottom, 120)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                approve()
            } label: {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    if isApproving {
                        ProgressView()
                            .tint(.colorTextPrimaryInverted)
                    }
                    Text(isApproving ? "Sharing demo…" : "Approve and share \(bundle.items.count) items")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(isApproving)
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .background(.colorBackgroundSurfaceless)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(width: 68, height: 68)
                .background(.colorFillPrimary, in: .circle)
                .accessibilityHidden(true)
            Text("Share this context?")
                .font(.largeTitle.bold())
                .tracking(-0.8)
                .foregroundStyle(.colorTextPrimary)
            Text("Nothing is shared until you approve this exact bundle.")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Where it goes")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Label("Space Abilities · Home + this conversation", systemImage: "house.and.flag.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("The group agent and members can use these details in chat and on Home.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
    }

    private var exactItems: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Exactly what you’re sharing")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            VStack(spacing: 0) {
                ForEach(bundle.items) { item in
                    PersonalContextItemRow(item: item, showsKind: true)
                    if item.id != bundle.items.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var lastingAccess: some View {
        Label {
            Text("These items stay available to this group until you remove access. New personal context still requires a new approval.")
        } icon: {
            Image(systemName: "clock.fill")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.colorTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var prototypeDisclosure: some View {
        Text("Prototype only. No server request or real context sharing occurs.")
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
    }

    private func approve() {
        guard !isApproving else { return }
        isApproving = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            onApproved()
        }
    }
}

private struct PersonalContextItemRow: View {
    let item: PersonalContextItem
    let showsKind: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: item.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorLava)
                .frame(width: 36, height: 36)
                .background(Color.colorLava.opacity(0.1), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text(showsKind ? "\(item.kind.rawValue) · \(item.detail)" : item.detail)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .accessibilityElement(children: .combine)
    }
}

/// The group-agent profile counterpart to the approval flow. It exposes only
/// what the user approved for this conversation, never the private catalog.
struct PersonalContextAgentAccessSection: View {
    let conversationId: String
    @State private var items: [PersonalContextItem]

    init(conversationId: String) {
        self.conversationId = conversationId
        _items = State(initialValue: PersonalContextPrototypeStore.items(for: conversationId))
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .frame(width: 44, height: 44)
                        .background(.colorLava, in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                        Text("Access to Shane’s context")
                            .font(.headline)
                            .foregroundStyle(.colorTextPrimary)
                        Text("\(items.count) items approved for this Home and conversation")
                            .font(.footnote)
                            .foregroundStyle(.colorTextSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    ForEach(items) { item in
                        Label(item.title, systemImage: item.symbolName)
                            .font(.footnote)
                            .foregroundStyle(.colorTextPrimary)
                    }
                }

                Label("Only explicitly approved context", systemImage: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(DesignConstants.Spacing.step4x)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .contain)
        }
    }
}
