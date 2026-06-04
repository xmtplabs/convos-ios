@testable import ConvosCore
import Foundation
import Testing

@Suite("Pairing Nonce Ledger")
struct PairingNonceLedgerTests {
    @Test("First joiner binds the nonce; resends keep matching")
    func firstJoinerBinds() {
        let ledger = PairingNonceLedger()
        let nonce = Data("nonce-a".utf8)

        #expect(ledger.joiner(for: nonce) == nil)
        ledger.bind(nonce: nonce, toJoiner: "joiner-1")
        #expect(ledger.joiner(for: nonce) == "joiner-1")
        // The legit joiner's resend loop rebinding is a no-op match.
        ledger.bind(nonce: nonce, toJoiner: "joiner-1")
        #expect(ledger.joiner(for: nonce) == "joiner-1")
    }

    @Test("A different joiner cannot steal an existing binding")
    func replayingJoinerCannotRebind() {
        let ledger = PairingNonceLedger()
        let nonce = Data("nonce-b".utf8)

        ledger.bind(nonce: nonce, toJoiner: "joiner-1")
        ledger.bind(nonce: nonce, toJoiner: "attacker")
        #expect(ledger.joiner(for: nonce) == "joiner-1")
    }

    @Test("Distinct nonces bind independently")
    func distinctNoncesAreIndependent() {
        let ledger = PairingNonceLedger()

        ledger.bind(nonce: Data("nonce-c".utf8), toJoiner: "joiner-1")
        ledger.bind(nonce: Data("nonce-d".utf8), toJoiner: "joiner-2")
        #expect(ledger.joiner(for: Data("nonce-c".utf8)) == "joiner-1")
        #expect(ledger.joiner(for: Data("nonce-d".utf8)) == "joiner-2")
    }
}
