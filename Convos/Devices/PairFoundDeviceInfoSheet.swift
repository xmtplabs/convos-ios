import SwiftUI

// First-install pairing prompt. When a fresh install finds another
// device's identity in the iCloud-synced keychain backup slot,
// ConversationsViewModel surfaces this sheet offering to pair with that
// device instead of continuing with the placeholder account. "Pair" runs
// the standard joiner pairing flow targeting the found device as the main
// device; "Skip" declines persistently.

/// Drives presentation of `PairFoundDeviceInfoSheet`: one backed-up
/// device identity discovered in iCloud, identified by the inboxId this
/// install would adopt on pair.
struct FoundDevicePairingPrompt: Identifiable, Equatable {
    let inboxId: String
    let deviceName: String?

    var id: String { inboxId }
}

struct PairFoundDeviceInfoSheet: View {
    let deviceName: String?
    let onPair: () -> Void
    let onSkip: () -> Void

    private var title: String {
        guard let deviceName else { return "Pair your other device?" }
        return "Pair \(deviceName)?"
    }

    private var subtitle: String {
        guard let deviceName else {
            return "Another device was found in iCloud, if you have it nearby, you can pair it now"
        }
        return "Your \(deviceName) was found in iCloud, if you have it nearby, you can pair it now"
    }

    private var primaryButtonTitle: String {
        guard let deviceName else { return "Pair device" }
        return "Pair \(deviceName)"
    }

    var body: some View {
        // No container-level accessibilityIdentifier: applied to the sheet
        // as a whole it propagates to every child element and clobbers the
        // two button identifiers below. Automation anchors on
        // pair-found-device-button instead.
        FeatureInfoSheet(
            title: title,
            subtitle: subtitle,
            primaryButtonTitle: primaryButtonTitle,
            primaryButtonAction: onPair,
            primaryButtonAccessibilityIdentifier: "pair-found-device-button",
            secondaryButtonTitle: "Skip",
            secondaryButtonAction: onSkip,
            secondaryButtonAccessibilityIdentifier: "skip-found-device-pairing-button"
        )
    }
}

#Preview("Named device") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) {
            PairFoundDeviceInfoSheet(deviceName: "Jarod's iPhone", onPair: {}, onSkip: {})
                .padding(.top, 20)
        }
}

#Preview("Unnamed device") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) {
            PairFoundDeviceInfoSheet(deviceName: nil, onPair: {}, onSkip: {})
                .padding(.top, 20)
        }
}
