import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

struct DocRoomView: View {
    @Bindable var viewModel: DocExperienceViewModel
    let initialDoc: DocStatus

    @State private var isReaderPresented: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    init(viewModel: DocExperienceViewModel, initialDoc: DocStatus) {
        self.viewModel = viewModel
        self.initialDoc = initialDoc
        _isReaderPresented = State(initialValue: viewModel.previewStage == .docSheet)
    }

    private var doc: DocStatus {
        viewModel.currentDoc(for: initialDoc.id, fallback: initialDoc)
    }

    private var content: DocContent? {
        viewModel.content(for: doc.id)
    }

    private var forYouItems: [DocWaitingItem] {
        viewModel.pendingItems(for: doc.id)
    }

    var body: some View {
        List {
            if dynamicTypeSize.isAccessibilitySize {
                Text(freshnessLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .docRoomRow()
            }

            DocActivationView(
                doc: doc,
                binding: viewModel.controlBinding(for: doc.id),
                contributionLine: viewModel.contributionLine,
                onShareNumber: { viewModel.presentShareNumber(for: doc) },
                onShareDoc: {
                    Task { await viewModel.shareDoc(doc) }
                }
            )
            .docRoomRow()

            if !forYouItems.isEmpty {
                DocForYouSection(
                    viewModel: viewModel,
                    verification: nil,
                    items: forYouItems,
                    composerScope: .room(doc.id)
                )
            }

            Section {
                DocChangesLedger(changes: content?.changes ?? [])
                    .docRoomRow()
            } header: {
                roomSectionTitle("History")
            }

            Section {
                Button {
                    isReaderPresented = true
                } label: {
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        Image(systemName: "doc.richtext")
                            .font(.title3)
                            .foregroundStyle(.colorLava)
                            .frame(width: 32.0, height: 32.0)
                        VStack(alignment: .leading, spacing: 4.0) {
                            Text("Read the doc")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.colorTextPrimary)
                            Text("Updated \(docRelativeTime(from: content?.updatedAt ?? doc.updatedAt))")
                                .font(.footnote)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(DesignConstants.Spacing.step4x)
                    .frame(minHeight: 64.0)
                    .background(
                        Color.colorBackgroundRaisedSecondary,
                        in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("doc-read-row")
                .docRoomRow()
            } header: {
                roomSectionTitle("Doc")
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(Color.colorBackgroundSurfaceless)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1.0) {
                    Text(doc.name)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(freshnessLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DocComposerBar(
                viewModel: viewModel,
                scope: .room(doc.id),
                messagePlaceholder: "Tell Doc about this doc…"
            )
        }
        .fullScreenCover(isPresented: $isReaderPresented) {
            DocReaderView(viewModel: viewModel, initialDoc: doc)
        }
        .task(id: requestRefreshKey) {
            viewModel.openRoom(for: doc)
        }
        .accessibilityIdentifier("doc-room")
    }

    private var freshnessLine: String {
        "\(doc.lastChange.who) \(doc.lastChange.what) · \(docCompactRelativeTime(from: doc.lastChange.at))"
    }

    private var requestRefreshKey: String {
        "\(doc.updatedAt.timeIntervalSince1970)|\(viewModel.dmViewModel?.conversation.id ?? "waiting")"
    }

    private func roomSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension View {
    func docRoomRow() -> some View {
        listRowInsets(
            EdgeInsets(
                top: DesignConstants.Spacing.step2x,
                leading: DesignConstants.Spacing.step4x,
                bottom: DesignConstants.Spacing.step2x,
                trailing: DesignConstants.Spacing.step4x
            )
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

private struct DocActivationView: View {
    let doc: DocStatus
    let binding: DocControlBinding?
    let contributionLine: String
    let onShareNumber: () -> Void
    let onShareDoc: () -> Void

    var body: some View {
        if let binding, binding.status == .live {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("In the group · \(docDisplayPhoneNumber(binding.lineNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .frame(minHeight: 44.0)
            .accessibilityIdentifier("doc-room-bound-status")
        } else if binding?.status == .pending {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView()
                    .controlSize(.small)
                Text("Adding Doc to the group…")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .frame(minHeight: 44.0)
            .accessibilityIdentifier("doc-room-binding-pending")
        } else if !contributionLine.isEmpty {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                Text(docDisplayPhoneNumber(contributionLine))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.colorTextPrimary)
                    .textSelection(.enabled)
                Text("Add Doc to the group and this doc updates itself")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                Button("Share", systemImage: "square.and.arrow.up", action: onShareNumber)
                    .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
                    .frame(minHeight: 44.0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignConstants.Spacing.step5x)
            .background(.colorBackgroundRaisedSecondary, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
            .accessibilityIdentifier("doc-room-unbound-hero")
        }

        if doc.shared != true {
            Button("Share doc", systemImage: "square.and.arrow.up", action: onShareDoc)
                .convosButtonStyle(.outlineCapsule(fullWidth: false))
                .frame(minHeight: 44.0)
                .accessibilityIdentifier("doc-room-share-document")
        }
    }
}

private struct DocChangesLedger: View {
    let changes: [DocLastChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if changes.isEmpty {
                Text("No changes yet.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(DesignConstants.Spacing.step4x)
            } else {
                ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                    if index > 0 { Divider().padding(.leading, DesignConstants.Spacing.step4x) }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step3x) {
                            changeDescription(change)
                            relativeTime(change)
                        }
                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                            changeDescription(change)
                            relativeTime(change)
                        }
                    }
                    .padding(DesignConstants.Spacing.step4x)
                }
            }
        }
        .background(
            Color.colorBackgroundRaisedSecondary,
            in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
        )
        .accessibilityIdentifier("doc-room-history")
    }

    private func changeDescription(_ change: DocLastChange) -> some View {
        Text("\(change.who) \(change.what)")
            .font(.subheadline)
            .foregroundStyle(.colorTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func relativeTime(_ change: DocLastChange) -> some View {
        Text(docCompactRelativeTime(from: change.at))
            .font(.caption)
            .foregroundStyle(.colorTextSecondary)
    }
}

func docCompactRelativeTime(from date: Date, relativeTo now: Date = Date()) -> String {
    let elapsed = now.timeIntervalSince(date)
    guard elapsed.isFinite, elapsed >= 60 else { return "now" }
    if elapsed < 60 * 60 { return "\(Int(elapsed / 60))m" }
    if elapsed < 24 * 60 * 60 { return "\(Int(elapsed / 3_600))h" }
    let safelyRepresentableDays = min(elapsed / 86_400, Double(Int.max) / 2)
    return "\(Int(safelyRepresentableDays))d"
}

private func docRelativeTime(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

func docDisplayPhoneNumber(_ rawNumber: String) -> String {
    let digits = rawNumber.filter(\.isNumber)
    let localDigits: Substring
    if digits.count == 11, digits.first == "1" {
        localDigits = digits.dropFirst()
    } else {
        localDigits = Substring(digits)
    }
    guard localDigits.count == 10 else { return rawNumber }
    let areaEnd = localDigits.index(localDigits.startIndex, offsetBy: 3)
    let prefixEnd = localDigits.index(areaEnd, offsetBy: 3)
    return "+1 (\(localDigits[..<areaEnd])) \(localDigits[areaEnd..<prefixEnd])-\(localDigits[prefixEnd...])"
}
