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

            DocActivationView(doc: doc) {
                viewModel.presentShareNumber(for: doc)
            }
            .docRoomRow()

            if !forYouItems.isEmpty {
                DocForYouSection(
                    viewModel: viewModel,
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
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32.0, height: 32.0)
                        VStack(alignment: .leading, spacing: 4.0) {
                            Text("Read the doc")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Updated \(docRelativeTime(from: content?.updatedAt ?? doc.updatedAt))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(DesignConstants.Spacing.step4x)
                    .frame(minHeight: 64.0)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14.0)
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
        .background(Color(uiColor: .systemGroupedBackground))
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
            DocScopedComposer(viewModel: viewModel, doc: doc)
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
    let onShare: () -> Void

    var body: some View {
        if doc.binding.state == .live {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("In the group · \(docDisplayPhoneNumber(doc.binding.number))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .frame(minHeight: 44.0)
            .accessibilityIdentifier("doc-room-bound-status")
        } else {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                Text(docDisplayPhoneNumber(doc.binding.number))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Text("Add Doc to the group and this doc updates itself")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button("Share", systemImage: "square.and.arrow.up", action: onShare)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44.0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignConstants.Spacing.step5x)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18.0))
            .accessibilityIdentifier("doc-room-unbound-hero")
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
                    .foregroundStyle(.secondary)
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
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14.0)
        )
        .accessibilityIdentifier("doc-room-history")
    }

    private func changeDescription(_ change: DocLastChange) -> some View {
        Text("\(change.who) \(change.what)")
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func relativeTime(_ change: DocLastChange) -> some View {
        Text(docCompactRelativeTime(from: change.at))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct DocScopedComposer: View {
    @Bindable var viewModel: DocExperienceViewModel
    let doc: DocStatus

    @State private var isSending: Bool = false
    @State private var didFail: Bool = false
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    private var scope: DocComposerScope {
        .room(doc.id)
    }

    private var text: Binding<String> {
        Binding(
            get: { viewModel.composerText(in: scope) },
            set: { viewModel.setComposerText($0, in: scope) }
        )
    }

    private var pendingPhotos: [DocPendingPhoto] {
        viewModel.pendingPhotos(in: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4.0) {
            if didFail {
                Text("Couldn't send. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("doc-room-send-error")
            }
            if !pendingPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        ForEach(pendingPhotos) { photo in
                            DocPhotoDraftThumbnail(photo: photo) {
                                viewModel.removePendingPhoto(id: photo.id, in: scope)
                            }
                        }
                    }
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: DesignConstants.Spacing.step2x) {
                    messageField
                    HStack {
                        Spacer(minLength: 0)
                        sendButton
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                    messageField
                    sendButton
                }
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var cleanText: String {
        viewModel.composerText(in: scope).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!cleanText.isEmpty || !pendingPhotos.isEmpty) &&
            !isSending &&
            viewModel.isDmReadyForDisplay
    }

    private var messageField: some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text("Tell Doc about this doc…")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
            }
            TextField("", text: text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($isFocused)
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .frame(minHeight: 44.0)
        .background(
            Color(uiColor: .tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 18.0)
        )
            .disabled(isSending)
            .submitLabel(.send)
            .onSubmit(send)
            .accessibilityLabel("Tell Doc about this doc")
            .accessibilityIdentifier("doc-room-message-field")
    }

    private var sendButton: some View {
        Button(action: send) {
            if isSending {
                ProgressView()
                    .frame(width: 44.0, height: 44.0)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32.0))
                    .frame(width: 44.0, height: 44.0)
            }
        }
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("doc-room-send")
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        didFail = false
        Task { @MainActor in
            let sent = await viewModel.sendComposerDraft(in: scope, doc: doc)
            didFail = !sent
            isSending = false
        }
    }
}

private func docCompactRelativeTime(from date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    if seconds < 60 * 60 { return "\(seconds / 60)m" }
    if seconds < 24 * 60 * 60 { return "\(seconds / 3_600)h" }
    return "\(seconds / 86_400)d"
}

private func docRelativeTime(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func docDisplayPhoneNumber(_ rawNumber: String) -> String {
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
