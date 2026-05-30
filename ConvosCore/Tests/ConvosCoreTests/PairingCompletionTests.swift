@testable import ConvosCore
import Foundation
import Testing

@Suite("PairingCompletion")
struct PairingCompletionTests {
    @Test("Initiator role reports isInitiator and carries the joiner name")
    func initiatorRole() {
        let role: PairingRole = .initiator(joinerDeviceName: "Jarod's iPad")
        #expect(role.isInitiator)
        #expect(role.optimisticDeviceName == "Jarod's iPad")
    }

    @Test("Joiner role is not the initiator and uses the generic name")
    func joinerRole() {
        let role: PairingRole = .joiner
        #expect(!role.isInitiator)
        #expect(role.optimisticDeviceName == "New device")
    }

    @Test("Posting carries the typed payload through to the observer")
    func postAndReadPayload() {
        let center = NotificationCenter()
        var received: PairingCompletion?
        let token = center.addObserver(
            forName: .pairingDidCompleteSuccessfully,
            object: nil,
            queue: nil
        ) { notification in
            received = notification.pairingCompletion
        }
        defer { center.removeObserver(token) }

        center.postPairingCompleted(PairingCompletion(role: .initiator(joinerDeviceName: "Pixel")))

        #expect(received == PairingCompletion(role: .initiator(joinerDeviceName: "Pixel")))
        #expect(received?.role.isInitiator == true)
    }

    @Test("A notification without a payload yields nil")
    func missingPayload() {
        let notification = Notification(name: .pairingDidCompleteSuccessfully)
        #expect(notification.pairingCompletion == nil)
    }
}
