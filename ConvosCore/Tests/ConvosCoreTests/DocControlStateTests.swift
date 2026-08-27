@testable import ConvosCore
import Foundation
import Testing

@Suite("Doc control messages")
struct DocControlStateTests {
    @Test("parses every control fact shape")
    func parsesEveryControlFactShape() throws {
        let lifecycle = try #require(DocControlMessage.parseEvent(Fixture.lifecycleReady))
        guard case .lifecycle(let lifecycleValue) = lifecycle.payload else {
            Issue.record("Expected lifecycle payload")
            return
        }
        #expect(lifecycleValue.status == .ready)
        #expect(lifecycle.sequence == 42)

        let line = try #require(DocControlMessage.parseEvent(Fixture.lineAvailable))
        guard case .line(let lineValue) = line.payload else {
            Issue.record("Expected line payload")
            return
        }
        #expect(lineValue.lineNumber == "+16283095734")

        for (message, status) in [
            (Fixture.verificationPending, DocControlVerification.Status.pending),
            (Fixture.verificationVerified, .verified),
            (Fixture.verificationExpired, .expired),
            (Fixture.verificationReleased, .released),
        ] {
            let event = try #require(DocControlMessage.parseEvent(message))
            guard case .verification(let value) = event.payload else {
                Issue.record("Expected verification payload")
                continue
            }
            #expect(value.status == status)
        }

        for (message, status) in [
            (Fixture.bindingPending, DocControlBinding.Status.pending),
            (Fixture.bindingLive, .live),
            (Fixture.bindingReleased, .released),
        ] {
            let event = try #require(DocControlMessage.parseEvent(message))
            guard case .binding(let value) = event.payload else {
                Issue.record("Expected binding payload")
                continue
            }
            #expect(value.status == status)
        }

        let google = try #require(DocControlMessage.parseEvent(Fixture.googlePending))
        guard case .googleDocs(let googleValue) = google.payload else {
            Issue.record("Expected Google Docs payload")
            return
        }
        #expect(googleValue.gate.status == .pending)
        #expect(googleValue.connection.status == .unknown)
    }

    @Test("rejects malformed, oversized, and unknown control messages")
    func rejectsInvalidControlMessages() {
        let unknownTopLevel = Fixture.lifecycleReady.replacingOccurrences(
            of: #""lifecycle":{"#,
            with: #""future":true,"lifecycle":{"#
        )
        let unknownNested = Fixture.lineAvailable.replacingOccurrences(
            of: #""lineNumber":"+16283095734""#,
            with: #""lineNumber":"+16283095734","future":true"#
        )
        let unknownKind = Fixture.lifecycleReady.replacingOccurrences(
            of: #""kind":"lifecycle""#,
            with: #""kind":"future""#
        )
        let malformedUUID = Fixture.lifecycleReady.replacingOccurrences(
            of: Fixture.instanceId,
            with: "not-a-uuid"
        )
        let malformedKey = Fixture.lineAvailable.replacingOccurrences(
            of: #""key":"line""#,
            with: #""key":"lifecycle""#
        )
        let unsafeSequence = Fixture.lifecycleReady.replacingOccurrences(
            of: #""seq":42"#,
            with: #""seq":9007199254740992"#
        )
        let oversized = Fixture.lifecycleReady + String(repeating: " ", count: 4_096)

        #expect(DocControlMessage.parseEvent(unknownTopLevel) == nil)
        #expect(DocControlMessage.parseEvent(unknownNested) == nil)
        #expect(DocControlMessage.parseEvent(unknownKind) == nil)
        #expect(DocControlMessage.parseEvent(malformedUUID) == nil)
        #expect(DocControlMessage.parseEvent(malformedKey) == nil)
        #expect(DocControlMessage.parseEvent(unsafeSequence) == nil)
        #expect(DocControlMessage.parseEvent(oversized) == nil)
        #expect(DocControlMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"state","docs":[]}"#) == nil)
        #expect(DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"state","docs":[]}"#) != nil)
    }

    @Test("orders each fact independently and ignores duplicate delivery")
    func reducesPerFactOrdering() throws {
        let lifecycle = try #require(DocControlMessage.parseEvent(Fixture.lifecycleReady))
        let olderLine = try #require(DocControlMessage.parseEvent(Fixture.lineAvailable))
        var snapshot = DocControlSnapshot(event: lifecycle)

        let appliedLine = snapshot.apply(olderLine)
        #expect(appliedLine)
        #expect(snapshot.lifecycle?.status == .ready)
        #expect(snapshot.line?.status == .available)
        let replayedLine = snapshot.apply(olderLine)
        #expect(!replayedLine)
        #expect(snapshot.latestSequencesByKey["lifecycle"] == 42)
        #expect(snapshot.latestSequencesByKey["line"] == 2)
    }

    @Test("release tombstones prevent an older live binding from returning")
    func bindingReleaseIsTerminalForOlderEvents() throws {
        let live = try #require(DocControlMessage.parseEvent(Fixture.bindingLive))
        let released = try #require(DocControlMessage.parseEvent(Fixture.bindingReleased))
        var snapshot = DocControlSnapshot(event: released)

        _ = snapshot.apply(live)
        #expect(snapshot.binding(forDocId: "tahoe-trip")?.status == .released)
        #expect(snapshot.latestSequencesByKey[released.key] == 31)
    }

    @Test("verified clears the challenge without an editorial resolution")
    func verificationClearsChallenge() throws {
        let pending = try #require(DocControlMessage.parseEvent(Fixture.verificationPending))
        let verified = try #require(DocControlMessage.parseEvent(Fixture.verificationVerified))
        var snapshot = DocControlSnapshot(event: pending)

        #expect(snapshot.verificationChallenge?.status == .pending)
        let appliedVerified = snapshot.apply(verified)
        #expect(appliedVerified)
        #expect(snapshot.verificationChallenge == nil)
        #expect(snapshot.latestSequencesByKey[DocControlMessage.verificationChallengeKey] == 12)
        #expect(snapshot.verificationsByKey["verification:owner:+14155550123"]?.status == .verified)
    }

    @Test("rejects another epoch in the same projection")
    func rejectsAnotherEpoch() throws {
        let first = try #require(DocControlMessage.parseEvent(Fixture.lifecycleReady))
        let otherEpochText = Fixture.lifecycleReady
            .replacingOccurrences(of: Fixture.epoch, with: "53A5C46C-31C1-409E-B277-9C84AFA23C91")
            .replacingOccurrences(of: #""seq":42"#, with: #""seq":43"#)
        let otherEpoch = try #require(DocControlMessage.parseEvent(otherEpochText))
        var snapshot = DocControlSnapshot(event: first)

        let appliedOtherEpoch = snapshot.apply(otherEpoch)
        #expect(!appliedOtherEpoch)
        #expect(snapshot.epoch == Fixture.epoch)
        #expect(snapshot.latestSequencesByKey["lifecycle"] == 42)
    }

    @Test("control requests match the Worker contract")
    func controlRequestFixtures() {
        #expect(DocControlRequestMessage.resyncText == #"⟦req⟧{"v":1,"t":"control"}"#)
        #expect(DocControlRequestMessage.renewVerificationText == #"⟦req⟧{"v":1,"t":"control","action":"renew_verification"}"#)
        #expect(DocWireMessage.isHiddenText(DocControlRequestMessage.resyncText))
    }

    private enum Fixture {
        static let instanceId: String = "F47AC10B-58CC-4372-A567-0E02B2C3D479"
        static let epoch: String = "7D9E6679-7425-40DE-944B-E07FC1F90AE7"

        static let lifecycleReady: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":42,"at":1787720400,"key":"lifecycle","kind":"lifecycle","lifecycle":{"status":"ready","conversationId":"abc","failureCode":null}}"#
        static let lineAvailable: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":2,"at":1787720400,"key":"line","kind":"line","line":{"status":"available","lineNumber":"+16283095734"}}"#
        static let verificationPending: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":10,"at":1787720400,"key":"verification:challenge","kind":"verification","verification":{"status":"pending","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":null,"code":"ABCD-EFGH-2345","smsBody":"VERIFY ABCD-EFGH-2345","expiresAt":1787724000,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        static let verificationVerified: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":12,"at":1787720500,"key":"verification:owner:+14155550123","kind":"verification","verification":{"status":"verified","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":"+14155550123","code":null,"smsBody":null,"expiresAt":1787724000,"verifiedAt":1787720500,"releasedAt":null,"clearsKey":"verification:challenge"}}"#
        static let verificationExpired: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":13,"at":1787724000,"key":"verification:challenge","kind":"verification","verification":{"status":"expired","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":null,"code":null,"smsBody":null,"expiresAt":1787724000,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        static let verificationReleased: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":14,"at":1787725000,"key":"verification:owner:+14155550123","kind":"verification","verification":{"status":"released","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":"+14155550123","code":null,"smsBody":null,"expiresAt":1787724000,"verifiedAt":1787720500,"releasedAt":1787725000,"clearsKey":null}}"#
        static let bindingPending: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":20,"at":1787720300,"key":"binding:doc:tahoe-trip","kind":"binding","binding":{"status":"pending","lineNumber":"+16283095734","threadId":null,"conversationType":null,"groupName":null,"docId":"tahoe-trip","intentAt":1787720300,"boundAt":null,"releasedAt":null,"supersedesKey":null}}"#
        static let bindingLive: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":30,"at":1787720400,"key":"binding:thread:+16283095734:thread-1","kind":"binding","binding":{"status":"live","lineNumber":"+16283095734","threadId":"thread-1","conversationType":"group","groupName":"Tahoe","docId":"tahoe-trip","intentAt":1787720300,"boundAt":1787720400,"releasedAt":null,"supersedesKey":"binding:doc:tahoe-trip"}}"#
        static let bindingReleased: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":31,"at":1787720600,"key":"binding:thread:+16283095734:thread-1","kind":"binding","binding":{"status":"released","lineNumber":"+16283095734","threadId":"thread-1","conversationType":"group","groupName":"Tahoe","docId":"tahoe-trip","intentAt":1787720300,"boundAt":1787720400,"releasedAt":1787720600,"supersedesKey":null}}"#
        static let googlePending: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":40,"at":1787720400,"key":"google:owner-inbox","kind":"google_docs","googleDocs":{"ownerInboxId":"owner-inbox","requestConversationId":null,"supersedesKey":null,"gate":{"status":"pending","requestId":"request-1","updatedAt":1787720400},"connection":{"status":"unknown","providerId":null,"updatedAt":1787720400}}}"#
    }
}
