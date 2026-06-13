import ConvosConnections
import SwiftUI
import UIKit

struct ConnectionFeedView: View {
    let conversation: MockConversation
    @Bindable var model: ExampleModel

    var body: some View {
        let messages = model.messagesByConversation[conversation.id] ?? []
        let details = model.detailsByKind[conversation.kind] ?? []
        let isEnabled = model.enabledConversationIds.contains(conversation.id)
        let writeCapabilities = model.writeCapabilities(for: conversation.kind)
        let relevantInvocations = model.invocationLog.filter { $0.conversationId == conversation.id }
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ConversationHeader(conversation: conversation, isEnabled: isEnabled)
                        if !details.isEmpty {
                            AuthorizationDetailsCard(kind: conversation.kind, details: details)
                        }
                        if !writeCapabilities.isEmpty {
                            WriteCapabilitiesCard(
                                conversation: conversation,
                                capabilities: writeCapabilities,
                                enabled: model.capabilityEnablement,
                                alwaysConfirm: model.alwaysConfirmByConversation[conversation.id] ?? false,
                                onToggleCapability: { capability, newValue in
                                    Task { await model.toggleCapability(capability, enabled: newValue, conversation: conversation) }
                                },
                                onToggleAlwaysConfirm: { newValue in
                                    Task { await model.toggleAlwaysConfirm(newValue, conversation: conversation) }
                                }
                            )
                        }
                        if !relevantInvocations.isEmpty {
                            InvocationLogCard(entries: relevantInvocations)
                        }
                        if messages.isEmpty {
                            EmptyFeedState(conversation: conversation, isEnabled: isEnabled)
                                .padding(.top, 40)
                        } else {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding()
                    .padding(.bottom, 80)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            controlsBar
        }
        .navigationTitle(conversation.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controlsBar: some View {
        VStack(spacing: 8) {
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await model.simulateSnapshot(for: conversation) }
                } label: {
                    Label("Read payload", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if conversation.kind == .calendar {
                    Button {
                        Task { await model.simulateAgentCreateEvent(for: conversation) }
                    } label: {
                        Label("Agent create", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if conversation.kind == .contacts {
                    Button {
                        Task { await model.simulateAgentCreateContact(for: conversation) }
                    } label: {
                        Label("Agent create", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if conversation.kind == .photos {
                    Button {
                        Task { await model.simulateAgentSaveImage(for: conversation) }
                    } label: {
                        Label("Agent save", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if conversation.kind == .health {
                    Button {
                        Task { await model.simulateAgentLogWater(for: conversation) }
                    } label: {
                        Label("Log 8oz water", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if conversation.kind == .music {
                    Button {
                        Task { await model.simulateAgentPauseMusic(for: conversation) }
                    } label: {
                        Label("Agent pause", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task { await model.clearMessages(for: conversation) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

private struct ConversationHeader: View {
    let conversation: MockConversation
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: conversation.kind.systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(conversation.kind.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isEnabled ? "Enabled" : "Disabled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isEnabled ? .green : .secondary)
            }
            Text("Conversation id: \(conversation.id)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct AuthorizationDetailsCard: View {
    let kind: ConnectionKind
    let details: [AuthorizationDetail]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Permissions for \(kind.displayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openAppSettings()
                } label: {
                    Label("Open in Settings", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
            }

            ForEach(details) { detail in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: systemImage(for: detail.status))
                        .foregroundStyle(color(for: detail.status))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.displayName)
                            .font(.callout)
                        Text(statusText(for: detail.status))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if let note = details.compactMap(\.note).first {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func systemImage(for status: ConnectionAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unavailable: return "minus.circle.fill"
        case .notDetermined: return "questionmark.circle"
        }
    }

    private func color(for status: ConnectionAuthorizationStatus) -> Color {
        switch status {
        case .authorized: return .green
        case .partial: return .orange
        case .denied, .unavailable: return .red
        case .notDetermined: return .secondary
        }
    }

    private func statusText(for status: ConnectionAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not yet requested"
        case .authorized: return "Requested"
        case .denied: return "Denied"
        case .partial(let missing): return "Partial (\(missing.count) missing)"
        case .unavailable: return "Unavailable"
        }
    }
}

private struct EmptyFeedState: View {
    let conversation: MockConversation
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: conversation.kind.systemImageName)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(isEnabled ? "No payloads yet." : "Connection is disabled for this conversation.")
                .font(.headline)
            Text(isEnabled
                 ? "Tap \"Simulate payload\" to force a snapshot, or generate activity on the device to trigger real observation."
                 : "Turn on the toggle for this conversation on the root screen to start receiving payloads here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MessageBubble: View {
    let message: MockMessageStore.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: message.payload.source.systemImageName)
                    .font(.caption)
                Text(message.payload.source.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(message.receivedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(message.payload.summary)
                .font(.callout)

            bodyDetails
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var bodyDetails: some View {
        switch message.payload.body {
        case .health(let payload):
            HealthBody(payload: payload)
        case .calendar(let payload):
            CalendarBody(payload: payload)
        case .location(let payload):
            LocationBody(payload: payload)
        case .contacts(let payload):
            ContactsBody(payload: payload)
        case .photos(let payload):
            PhotosBody(payload: payload)
        case .music(let payload):
            MusicBody(payload: payload)
        case .motion(let payload):
            MotionBody(payload: payload)
        case .homeKit(let payload):
            HomeBody(payload: payload)
        case .screenTime(let payload):
            ScreenTimeBody(payload: payload)
        case .unknown(let rawType, _):
            Text("Unknown body type: \(rawType)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WriteCapabilitiesCard: View {
    let conversation: MockConversation
    let capabilities: [ConnectionCapability]
    let enabled: [ExampleModel.CapabilityKey: Bool]
    let alwaysConfirm: Bool
    let onToggleCapability: (ConnectionCapability, Bool) -> Void
    let onToggleAlwaysConfirm: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Write capabilities")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Separate from the read toggle on the previous screen. Each verb is a distinct user consent.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(capabilities, id: \.self) { capability in
                Toggle(
                    isOn: Binding(
                        get: { enabled[ExampleModel.CapabilityKey(kind: conversation.kind, capability: capability, conversationId: conversation.id)] ?? false },
                        set: { newValue in onToggleCapability(capability, newValue) }
                    )
                ) {
                    HStack {
                        Image(systemName: icon(for: capability))
                            .font(.caption)
                            .frame(width: 20)
                        Text(capability.displayName)
                            .font(.callout)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            Toggle(isOn: Binding(
                get: { alwaysConfirm },
                set: { newValue in onToggleAlwaysConfirm(newValue) }
            )) {
                HStack {
                    Image(systemName: "exclamationmark.shield")
                        .font(.caption)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Always confirm writes")
                            .font(.callout)
                        Text("Off by default. When on, each write waits for your approval (or returns requiresConfirmation if the app is backgrounded).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func icon(for capability: ConnectionCapability) -> String {
        switch capability {
        case .read: return "eye"
        case .writeCreate: return "plus.circle"
        case .writeUpdate: return "pencil"
        case .writeDelete: return "trash"
        }
    }
}

private struct InvocationLogCard: View {
    let entries: [RecordedInvocation]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Invocation log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(entries.count) entries")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(entries.reversed().prefix(5)) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: statusIcon(for: entry.result.status))
                            .font(.caption)
                            .foregroundStyle(statusColor(for: entry.result.status))
                        Text(entry.invocation.action.name)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(entry.recordedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(statusLabel(for: entry.result.status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let message = entry.result.errorMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusIcon(for status: ConnectionInvocationResult.Status) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .capabilityNotEnabled, .capabilityRevoked: return "lock.fill"
        case .requiresConfirmation: return "questionmark.circle.fill"
        case .authorizationDenied: return "hand.raised.fill"
        case .executionFailed: return "xmark.octagon.fill"
        case .unknownAction: return "questionmark.square.fill"
        }
    }

    private func statusColor(for status: ConnectionInvocationResult.Status) -> Color {
        switch status {
        case .success: return .green
        case .capabilityNotEnabled, .capabilityRevoked, .requiresConfirmation: return .orange
        case .authorizationDenied, .executionFailed, .unknownAction: return .red
        }
    }

    private func statusLabel(for status: ConnectionInvocationResult.Status) -> String {
        switch status {
        case .success: return "Success"
        case .capabilityNotEnabled: return "Capability not enabled"
        case .capabilityRevoked: return "Capability revoked"
        case .requiresConfirmation: return "Requires confirmation"
        case .authorizationDenied: return "Authorization denied"
        case .executionFailed: return "Execution failed"
        case .unknownAction: return "Unknown action"
        }
    }
}

private struct ScreenTimeBody: View {
    let payload: ScreenTimePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: payload.authorized ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(payload.authorized ? .green : .secondary)
                Text(payload.authorized ? "Authorized" : "Not authorized")
                    .font(.caption.weight(.medium))
            }
            if payload.selectedApplicationCount + payload.selectedCategoryCount + payload.selectedWebDomainCount > 0 {
                Text("Selection: \(payload.selectedApplicationCount) apps · \(payload.selectedCategoryCount) categories · \(payload.selectedWebDomainCount) web domains")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No app / category selection yet. A DeviceActivityMonitor extension is needed to surface usage hours.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HomeBody: View {
    let payload: HomePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if payload.homes.isEmpty {
                Text("No homes configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(payload.homes) { home in
                    HStack {
                        Image(systemName: home.isPrimary ? "house.fill" : "house")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(home.name)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(home.roomCount) rooms · \(home.accessoryCount) accessories")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct MotionBody: View {
    let payload: MotionPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let activity = payload.activity {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: activity.type))
                        .font(.caption.weight(.medium))
                    Text(activity.type.rawValue.capitalized)
                        .font(.caption.weight(.medium))
                }
                Text("Confidence: \(activity.confidence.rawValue) · Since \(activity.startDate, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No activity classified yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for type: MotionActivityType) -> String {
        switch type {
        case .stationary: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .automotive: return "car.fill"
        case .cycling: return "figure.outdoor.cycle"
        case .unknown: return "questionmark"
        }
    }
}

private struct MusicBody: View {
    let payload: MusicPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let nowPlaying = payload.nowPlaying {
                Text(nowPlaying.title ?? "(untitled)")
                    .font(.caption.weight(.semibold))
                if let artist = nowPlaying.artist {
                    Text(artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let album = nowPlaying.album {
                    Text("from \(album)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(Self.format(nowPlaying.playbackTimeSeconds)) / \(Self.format(nowPlaying.durationSeconds))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: iconFor(state: payload.playbackState))
                    .font(.caption2)
                Text(payload.playbackState.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func iconFor(state: MusicPlaybackState) -> String {
        switch state {
        case .playing: return "play.fill"
        case .paused: return "pause.fill"
        case .stopped: return "stop.fill"
        case .interrupted: return "exclamationmark.triangle"
        case .seekingForward: return "forward.fill"
        case .seekingBackward: return "backward.fill"
        case .unknown: return "questionmark"
        }
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PhotosBody: View {
    let payload: PhotosPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Badge(label: "photos", count: payload.photoCount)
                Badge(label: "videos", count: payload.videoCount)
                Badge(label: "screenshots", count: payload.screenshotCount)
                Badge(label: "live", count: payload.livePhotoCount)
            }
            Text("Recent \(payload.recentAssets.count) of \(payload.totalAssetCount) total")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(payload.recentAssets.prefix(4)) { asset in
                HStack {
                    Image(systemName: iconFor(type: asset.mediaType, subtype: asset.subtype))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(asset.subtype == .none ? asset.mediaType.rawValue : asset.subtype.rawValue)
                        .font(.caption.weight(.medium))
                    Spacer()
                    if let date = asset.creationDate {
                        Text(date, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func iconFor(type: PhotoMediaType, subtype: PhotoMediaSubtype) -> String {
        switch subtype {
        case .screenshot: return "camera.viewfinder"
        case .livePhoto: return "livephoto"
        case .panorama: return "pano"
        case .hdr: return "square.2.layers.3d"
        case .slomo, .timelapse: return "video"
        default: break
        }
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "waveform"
        case .unknown: return "questionmark.square"
        }
    }
}

private struct Badge: View {
    let label: String
    let count: Int

    var body: some View {
        if count >= 1 {
            Text("\(count) \(label)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
        }
    }
}

private struct ContactsBody: View {
    let payload: ContactsPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(payload.totalContactCount) total — showing first \(payload.previewContacts.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(payload.previewContacts.prefix(5)) { contact in
                HStack {
                    Text(contact.displayName)
                        .font(.caption.weight(.medium))
                    Spacer()
                    if contact.hasEmail {
                        Image(systemName: "envelope.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if contact.hasPhone {
                        Image(systemName: "phone.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if payload.previewContacts.count > 5 {
                Text("…and \(payload.previewContacts.count - 5) more in preview")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LocationBody: View {
    let payload: LocationPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if payload.events.isEmpty {
                Text("No events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(payload.events) { event in
                    HStack {
                        Image(systemName: icon(for: event.type))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label(for: event.type))
                                .font(.caption.weight(.medium))
                            Text("\(formatCoord(event.latitude)), \(formatCoord(event.longitude)) ±\(Int(event.horizontalAccuracy))m")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.eventDate, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func icon(for type: LocationEventType) -> String {
        switch type {
        case .significantChange: return "arrow.triangle.turn.up.right.circle"
        case .visitArrival: return "mappin.and.ellipse"
        case .visitDeparture: return "figure.walk.departure"
        }
    }

    private func label(for type: LocationEventType) -> String {
        switch type {
        case .significantChange: return "Significant change"
        case .visitArrival: return "Arrival"
        case .visitDeparture: return "Departure"
        }
    }

    private func formatCoord(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

private struct HealthBody: View {
    let payload: HealthPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if payload.samples.isEmpty {
                Text("No samples in window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(payload.samples.prefix(5).enumerated()), id: \.offset) { _, sample in
                    HStack {
                        Text(sample.type.displayName)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(String(format: "%.1f", sample.value)) \(sample.unit)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if payload.samples.count > 5 {
                    Text("…and \(payload.samples.count - 5) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CalendarBody: View {
    let payload: CalendarPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if payload.events.isEmpty {
                Text("No events in window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(payload.events.prefix(4)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title ?? "(untitled)")
                            .font(.caption.weight(.medium))
                        Text(event.startDate, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            + Text("  •  ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            + Text(event.startDate, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if payload.events.count > 4 {
                    Text("…and \(payload.events.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
