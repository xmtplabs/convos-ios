import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

struct DocRoomView: View {
    @Bindable var viewModel: DocExperienceViewModel
    let initialDoc: DocStatus

    @State private var isReaderPresented: Bool

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
            DocActivationView(doc: doc) {
                viewModel.presentShareNumber(for: doc)
            }
            .docRoomRow()

            if !forYouItems.isEmpty {
                DocForYouSection(viewModel: viewModel, items: forYouItems)
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
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1.0) {
                    Text(doc.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(freshnessLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                    HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step3x) {
                        Text("\(change.who) \(change.what)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(docCompactRelativeTime(from: change.at))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
}

private struct DocScopedComposer: View {
    @Bindable var viewModel: DocExperienceViewModel
    let doc: DocStatus

    @State private var text: String = ""
    @State private var isSending: Bool = false
    @State private var didFail: Bool = false
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    @FocusState private var focus: MessagesViewInputFocus?

    private var pendingAttachments: [PendingMediaAttachment] {
        viewModel.dmViewModel?.pendingMediaAttachments ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4.0) {
            if didFail {
                Text("Couldn't send. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("doc-room-send-error")
            }
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        ForEach(pendingAttachments) { attachment in
                            DocAttachmentThumbnail(attachment: attachment) {
                                viewModel.dmViewModel?.removeMediaAttachment(id: attachment.id)
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                TextField("Tell Doc about this doc…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .message)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(minHeight: 44.0)
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 18.0)
                    )
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityIdentifier("doc-room-message-field")
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
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .focusCoordinatorSync(
            focusState: $focus,
            coordinator: focusCoordinator,
            resetToken: viewModel.dmViewModel?.conversation.id
        )
    }

    private var cleanText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!cleanText.isEmpty || !pendingAttachments.isEmpty) &&
            !isSending &&
            viewModel.isDmReadyForDisplay
    }

    private func send() {
        let instruction = cleanText
        guard canSend else { return }
        if !pendingAttachments.isEmpty, let dmViewModel = viewModel.dmViewModel {
            dmViewModel.messageText = instruction.isEmpty ? "\(doc.name):" : "\(doc.name): \(instruction)"
            let screenshotCount = pendingAttachments.count
            dmViewModel.onSendMessage(focusCoordinator: focusCoordinator)
            viewModel.didSend(screenshotCount: screenshotCount)
            text = ""
            return
        }
        isSending = true
        didFail = false
        Task { @MainActor in
            let sent = await viewModel.sendScopedInstruction(instruction, for: doc)
            if sent {
                text = ""
            } else {
                didFail = true
            }
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
