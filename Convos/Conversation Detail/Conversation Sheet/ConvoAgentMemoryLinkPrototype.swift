import ConvosComposer
import SwiftUI

/// Demo-only personal context that can be suggested for the current Home and
/// conversation. The production version must be assembled from the signed-in
/// user's private context service and must never publish an item without an
/// explicit, destination-scoped approval.
struct PersonalContextItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable {
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

    static let catalog: [PersonalContextItem] = suggestedForCurrentConvo.items + [
        PersonalContextItem(
            id: "quiet-hotel-room",
            title: "Quiet hotel room",
            detail: "Away from elevators when available",
            symbolName: "bed.double.fill",
            kind: .preference
        ),
        PersonalContextItem(
            id: "past-trip-notes",
            title: "Past trip notes",
            detail: "Places and plans you previously saved",
            symbolName: "clock.arrow.circlepath",
            kind: .memory
        ),
        PersonalContextItem(
            id: "packing-checklist",
            title: "Packing checklist.md",
            detail: "A reusable personal travel checklist",
            symbolName: "checklist",
            kind: .file
        ),
        PersonalContextItem(
            id: "loyalty-programs",
            title: "Airline loyalty programs",
            detail: "Connected programs; account numbers stay hidden",
            symbolName: "link.circle.fill",
            kind: .connection
        ),
    ]
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

enum PersonalContextShareDestination: String, CaseIterable, Hashable, Identifiable {
    case groupChat
    case tripPlanner
    case sharedNote
    case members

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groupChat: "Group chat"
        case .tripPlanner: "Trip planner"
        case .sharedNote: "Shared note"
        case .members: "Members"
        }
    }

    var subtitle: String {
        switch self {
        case .groupChat: "Share a context card with everyone"
        case .tripPlanner: "Add details to the Home travel widget"
        case .sharedNote: "Add selected details to a Home note"
        case .members: "Add context to your Home member profile"
        }
    }

    var systemImage: String {
        switch self {
        case .groupChat: "bubble.left.and.bubble.right.fill"
        case .tripPlanner: "airplane"
        case .sharedNote: "note.text"
        case .members: "person.2.fill"
        }
    }

    var surfaceLabel: String {
        self == .groupChat ? "Conversation" : "Home"
    }

    var approvalTitle: String {
        switch self {
        case .groupChat: "Share with Group chat"
        case .tripPlanner: "Add to Trip planner"
        case .sharedNote: "Add to Shared note"
        case .members: "Add to Members"
        }
    }

    var resultTitle: String {
        switch self {
        case .groupChat: "Shared with Group chat"
        case .tripPlanner: "Added to Trip planner"
        case .sharedNote: "Added to Shared note"
        case .members: "Added to Members"
        }
    }

    var effectDescription: String {
        switch self {
        case .groupChat:
            "Everyone in this group can see the context card, and Space Abilities can use the approved details in this conversation."
        case .tripPlanner:
            "The Home travel widget can use these details for planning. Group members can see what the widget shows."
        case .sharedNote:
            "The selected details are added to a note on Home where group members can read and edit them."
        case .members:
            "These details appear with your member entry on Home and can be used by the group agent."
        }
    }
}

struct PersonalContextShareReceipt: Hashable, Identifiable {
    let id: String
    let destination: PersonalContextShareDestination
    let items: [PersonalContextItem]

    init(destination: PersonalContextShareDestination, items: [PersonalContextItem]) {
        id = "\(destination.rawValue):\(items.map(\.id).joined(separator: ","))"
        self.destination = destination
        self.items = items
    }
}

/// Primary entry point from the Group composer's attachment menu. It starts
/// from the whole private catalog, selects only what appears useful to this
/// Home and recent conversation, and requires a destination-bound approval.
struct PersonalContextShareView: View {
    let conversationId: String
    let onShared: (PersonalContextShareReceipt) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var selectedDestination: PersonalContextShareDestination = .groupChat
    @State private var selectedItemIds: Set<String> = Set(
        PersonalContextBundle.suggestedForCurrentConvo.items.map(\.id)
    )
    @State private var reviewingReceipt: PersonalContextShareReceipt?

    private let suggestedItemIds: Set<String> = Set(
        PersonalContextBundle.suggestedForCurrentConvo.items.map(\.id)
    )

    private var selectedItems: [PersonalContextItem] {
        PersonalContextBundle.catalog.filter { selectedItemIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                    heading
                    destinationPicker
                    suggestionReason
                    contextLibrary
                    prototypeDisclosure
                }
                .padding(.horizontal, DesignConstants.Spacing.step5x)
                .padding(.top, DesignConstants.Spacing.step5x)
                .padding(.bottom, 120)
            }
            .background(.colorBackgroundSurfaceless)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(item: $reviewingReceipt) { receipt in
                PersonalContextShareReviewView(receipt: receipt) {
                    onShared(receipt)
                    dismiss()
                }
            }
            .safeAreaInset(edge: .bottom) {
                reviewButton
            }
        }
        .environment(\.colorScheme, .light)
        .accessibilityIdentifier("personal-context-share-\(conversationId)")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Share what helps")
                .font(.system(size: 38, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(.colorTextPrimary)
            Text("Choose a place in this group, then approve the exact parts of your personal context it can use.")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Where should it go?")
                .font(.title2.bold())
                .foregroundStyle(.colorTextPrimary)

            VStack(spacing: 0) {
                ForEach(PersonalContextShareDestination.allCases) { destination in
                    Button {
                        selectedDestination = destination
                    } label: {
                        destinationRow(destination)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedDestination == destination ? .isSelected : [])
                    if destination != PersonalContextShareDestination.allCases.last {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
        }
    }

    private func destinationRow(_ destination: PersonalContextShareDestination) -> some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: destination.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(selectedDestination == destination ? .colorTextPrimaryInverted : .colorTextPrimary)
                .frame(width: 38, height: 38)
                .background(selectedDestination == destination ? Color.colorFillPrimary : Color.colorFillSubtle, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Text(destination.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text(destination.surfaceLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                }
                Text(destination.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
            Spacer(minLength: DesignConstants.Spacing.step2x)
            Image(systemName: selectedDestination == destination ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selectedDestination == destination ? .colorLava : .colorTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .contentShape(.rect)
    }

    private var suggestionReason: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "sparkles")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorLava)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("\(suggestedItemIds.count) useful details selected")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Suggested from this Home and recent trip-planning conversation. You can change every selection.")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorLava.opacity(0.08), in: .rect(cornerRadius: 16))
    }

    private var contextLibrary: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
            HStack(alignment: .firstTextBaseline) {
                Text("My context")
                    .font(.title2.bold())
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                Text("\(selectedItemIds.count) of \(PersonalContextBundle.catalog.count) selected")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }

            ForEach(PersonalContextItem.Kind.allCases, id: \.self) { kind in
                let items: [PersonalContextItem] = PersonalContextBundle.catalog.filter { $0.kind == kind }
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind.rawValue)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                        .padding(.bottom, DesignConstants.Spacing.step2x)
                    ForEach(items) { item in
                        Button {
                            toggle(item)
                        } label: {
                            PersonalContextSelectableRow(
                                item: item,
                                isSuggested: suggestedItemIds.contains(item.id),
                                isSelected: selectedItemIds.contains(item.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedItemIds.contains(item.id) ? .isSelected : [])
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    private var reviewButton: some View {
        Button {
            reviewingReceipt = PersonalContextShareReceipt(
                destination: selectedDestination,
                items: selectedItems
            )
        } label: {
            VStack(spacing: DesignConstants.Spacing.stepX) {
                Text("Review \(selectedItemIds.count) items")
                    .font(.body.weight(.semibold))
                Text("For \(selectedDestination.title)")
                    .font(.footnote)
            }
            .foregroundStyle(.colorTextPrimaryInverted)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(selectedItemIds.isEmpty)
        .opacity(selectedItemIds.isEmpty ? 0.4 : 1)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.colorBackgroundSurfaceless)
        .accessibilityHint("Shows the exact destination and values before sharing")
    }

    private var prototypeDisclosure: some View {
        Label("Prototype data is illustrative. No real personal context leaves your account.", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ item: PersonalContextItem) {
        if selectedItemIds.contains(item.id) {
            selectedItemIds.remove(item.id)
        } else {
            selectedItemIds.insert(item.id)
        }
    }
}

private struct PersonalContextSelectableRow: View {
    let item: PersonalContextItem
    let isSuggested: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: item.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 40, height: 40)
                .background(.colorFillSubtle, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    if isSuggested {
                        Text("Suggested")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
                Text(item.detail)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignConstants.Spacing.step2x)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? .colorLava : .colorTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct PersonalContextShareReviewView: View {
    let receipt: PersonalContextShareReceipt
    let onShared: () -> Void

    @State private var isSharing: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                heading
                destination
                exactItems
                approvalBoundary
                prototypeDisclosure
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.bottom, 120)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            shareButton
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Share this context?")
                .font(.largeTitle.bold())
                .tracking(-0.8)
                .foregroundStyle(.colorTextPrimary)
            Text("This approval covers only the destination and values shown below.")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destination: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: receipt.destination.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(width: 48, height: 48)
                .background(.colorFillPrimary, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(receipt.destination.title)
                    .font(.title3.bold())
                    .foregroundStyle(.colorTextPrimary)
                Text(receipt.destination.effectDescription)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                ForEach(receipt.items) { item in
                    PersonalContextItemRow(item: item, showsKind: true)
                    if item.id != receipt.items.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var approvalBoundary: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Label("Nothing else from My context is shared", systemImage: "checkmark.shield.fill")
            Label("New details always require a new approval", systemImage: "hand.raised.fill")
            Label("Remove this group’s access from agent settings", systemImage: "arrow.uturn.backward.circle.fill")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.colorTextSecondary)
    }

    private var prototypeDisclosure: some View {
        Text("Prototype only. This simulates the destination update without sending personal data to a server.")
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var shareButton: some View {
        Button {
            approve()
        } label: {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                if isSharing {
                    ProgressView().tint(.colorTextPrimaryInverted)
                }
                Text(isSharing ? "Sharing demo…" : receipt.destination.approvalTitle)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.colorTextPrimaryInverted)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isSharing)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.colorBackgroundSurfaceless)
    }

    private func approve() {
        guard !isSharing else { return }
        isSharing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            onShared()
        }
    }
}

struct PersonalContextShareConfirmationView: View {
    let receipt: PersonalContextShareReceipt
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.colorTextPrimary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(receipt.destination.resultTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("\(receipt.items.count) approved context items · Demo")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            Spacer(minLength: DesignConstants.Spacing.step2x)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss context confirmation")
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .accessibilityElement(children: .contain)
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
