@testable import Convos
import ConvosCore
import Foundation
import Testing

@MainActor
struct DocControlViewModelTests {
    @Test("first-run reducer sequences and skips completed control steps")
    func firstRunReducerSequence() {
        #expect(DocFirstRunReducer.step(
            hasCompletedWelcome: false,
            hasCompletedFirstRun: false,
            hasVerifiedNumber: false,
            hasCompletedVerificationHello: false,
            hasGrantedGoogleDocs: false
        ) == .welcome)
        #expect(DocFirstRunReducer.step(
            hasCompletedWelcome: true,
            hasCompletedFirstRun: false,
            hasVerifiedNumber: false,
            hasCompletedVerificationHello: false,
            hasGrantedGoogleDocs: true
        ) == .verify)
        #expect(DocFirstRunReducer.step(
            hasCompletedWelcome: true,
            hasCompletedFirstRun: false,
            hasVerifiedNumber: true,
            hasCompletedVerificationHello: false,
            hasGrantedGoogleDocs: false
        ) == .sayHello)
        #expect(DocFirstRunReducer.step(
            hasCompletedWelcome: true,
            hasCompletedFirstRun: false,
            hasVerifiedNumber: true,
            hasCompletedVerificationHello: true,
            hasGrantedGoogleDocs: false
        ) == .connectGoogle)
        #expect(DocFirstRunReducer.step(
            hasCompletedWelcome: true,
            hasCompletedFirstRun: false,
            hasVerifiedNumber: true,
            hasCompletedVerificationHello: true,
            hasGrantedGoogleDocs: true
        ) == .home)
        #expect(DocFirstRunReducer.step(
            hasCompletedWelcome: true,
            hasCompletedFirstRun: true,
            hasVerifiedNumber: false,
            hasCompletedVerificationHello: false,
            hasGrantedGoogleDocs: false
        ) == .home)
    }

    @Test("control facts advance first run and persist completion")
    func controlFactsAdvanceFirstRun() throws {
        let fixture = try Fixture(hasCompletedWelcome: true)
        let viewModel = fixture.viewModel()

        #expect(viewModel.firstRunStep == .verify)
        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "verified", text: Fixture.verificationVerified, date: 10)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.firstRunStep == .sayHello)
        viewModel.completeVerificationHello()
        #expect(viewModel.firstRunStep == .connectGoogle)

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "granted", text: Fixture.googleGranted, date: 11)],
            agentInboxId: Fixture.agentInboxId
        )

        #expect(viewModel.firstRunStep == .home)
        #expect(viewModel.hasCompletedFirstRun)
        #expect(fixture.defaults.bool(
            forKey: DocExperienceViewModel.storageKey("firstRun", accountIdentifier: "registering")
        ))
    }

    @Test("pre-granted Google waits only for verification")
    func preGrantedGoogleSkipsConnect() throws {
        let fixture = try Fixture(hasCompletedWelcome: true)
        let viewModel = fixture.viewModel()

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "granted", text: Fixture.googleGranted, date: 10)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.firstRunStep == .verify)

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "verified", text: Fixture.verificationVerified, date: 11)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.firstRunStep == .sayHello)
        viewModel.completeVerificationHello()
        #expect(viewModel.firstRunStep == .home)
    }

    @Test("relaunch resumes a pending verification")
    func relaunchResumesVerification() throws {
        let fixture = try Fixture(hasCompletedWelcome: true)
        let firstLaunch = fixture.viewModel()
        firstLaunch.ingestAggregatedMessages(
            [fixture.message(id: "pending", text: Fixture.verificationPending, date: 10)],
            agentInboxId: Fixture.agentInboxId
        )

        let relaunched = fixture.viewModel()

        #expect(relaunched.firstRunStep == .verify)
        #expect(relaunched.verificationControl?.status == .pending)
    }

    @Test("verification request and submit facts drive recovery states")
    func verificationFactsDriveFlow() throws {
        let fixture = try Fixture(hasCompletedWelcome: true)
        let viewModel = fixture.viewModel()

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "request-sent", text: Fixture.verificationRequestSent, date: 10)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.verificationFlowState == .enteringCode(
            number: "+14155550123",
            attemptFailed: false
        ))

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "submit-failed", text: Fixture.verificationSubmitFailed, date: 11)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.verificationFlowState == .enteringCode(
            number: "+14155550123",
            attemptFailed: true
        ))

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "request-failed", text: Fixture.verificationRequestFailed, date: 12)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.verificationFlowState == .fallback(number: "+14155550123"))
    }

    @Test("outbound verified fact completes phone verification")
    func outboundVerifiedFactCompletesFlow() throws {
        let fixture = try Fixture(hasCompletedWelcome: true)
        let viewModel = fixture.viewModel()

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "request-sent", text: Fixture.verificationRequestSent, date: 10)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.verificationFlowState == .enteringCode(
            number: "+14155550123",
            attemptFailed: false
        ))

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "verified", text: Fixture.verificationOutboundVerified, date: 11)],
            agentInboxId: Fixture.agentInboxId
        )

        #expect(viewModel.verificationFlowState == .verified(number: "+14155550123"))
        #expect(viewModel.firstRunStep == .sayHello)
    }

    @Test("pre-verified number resumes at the optional hello")
    func preVerifiedNumberShowsHello() throws {
        let fixture = try Fixture(hasCompletedWelcome: true)
        let firstLaunch = fixture.viewModel()
        firstLaunch.ingestAggregatedMessages(
            [fixture.message(id: "verified", text: Fixture.verificationVerified, date: 10)],
            agentInboxId: Fixture.agentInboxId
        )

        let relaunched = fixture.viewModel()

        #expect(relaunched.firstRunStep == .sayHello)
        relaunched.completeVerificationHello()
        #expect(relaunched.firstRunStep == .connectGoogle)
    }

    @Test("regressions stay on home after first run")
    func regressionsStayOnHome() throws {
        let fixture = try Fixture(hasCompletedWelcome: true)
        let viewModel = fixture.viewModel()
        viewModel.ingestAggregatedMessages(
            [
                fixture.message(id: "verified", text: Fixture.verificationVerified, date: 10),
                fixture.message(id: "granted", text: Fixture.googleGranted, date: 11),
            ],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.firstRunStep == .sayHello)
        viewModel.completeVerificationHello()
        #expect(viewModel.firstRunStep == .home)

        viewModel.ingestAggregatedMessages(
            [
                fixture.message(id: "renewed", text: Fixture.verificationRenewed, date: 12),
                fixture.message(id: "revoked", text: Fixture.googleRevoked, date: 13),
            ],
            agentInboxId: Fixture.agentInboxId
        )

        #expect(viewModel.firstRunStep == .home)
        #expect(viewModel.verificationControl?.status == .pending)
        #expect(viewModel.shouldShowGoogleConnectCard)
    }

    @Test("reset restarts first run")
    func resetRestartsFirstRun() async throws {
        let fixture = try Fixture(hasCompletedWelcome: true, hasCompletedFirstRun: true)
        let viewModel = fixture.viewModel()
        #expect(viewModel.firstRunStep == .home)

        DocExperienceViewModel.resetAgentBinding(
            session: fixture.session,
            defaults: fixture.defaults
        )
        try await Task.sleep(for: .milliseconds(10))

        #expect(viewModel.firstRunStep == .welcome)
    }

    @Test("verification clears without an editorial resolution")
    func verificationClearsFromControl() throws {
        let fixture = try Fixture()
        let viewModel = fixture.viewModel()

        viewModel.ingestAggregatedMessages(
            [
                fixture.message(id: "legacy-item", text: Fixture.legacyVerificationItem, date: 9),
                fixture.message(id: "pending", text: Fixture.verificationPending, date: 10),
            ],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.verificationControl?.status == .pending)
        #expect(viewModel.pendingItems.map(\.kind) == [.verifyNumber])
        #expect(viewModel.visiblePendingItems.isEmpty)

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "verified", text: Fixture.verificationVerified, date: 12)],
            agentInboxId: Fixture.agentInboxId
        )

        #expect(viewModel.verificationControl == nil)
        #expect(viewModel.pendingItems.map(\.kind) == [.verifyNumber])
        #expect(viewModel.visiblePendingItems.isEmpty)
    }

    @Test("pending Google control suppresses another request")
    func pendingGoogleSuppressesDuplicateRequest() throws {
        let fixture = try Fixture(hasCompletedWelcome: true, hasCompletedFirstRun: true)
        let viewModel = fixture.viewModel()

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "google", text: Fixture.googlePending, date: 20)],
            agentInboxId: Fixture.agentInboxId
        )

        #expect(viewModel.shouldShowGoogleConnectCard)
        #expect(viewModel.isWaitingForGoogleApproval)
        #expect(viewModel.isConnectingGoogleDocs)
        #expect(!viewModel.canRequestGoogleDocs)
    }

    @Test("lifecycle renders independently of editorial state")
    func lifecycleWithoutEditorialState() throws {
        let fixture = try Fixture()
        let viewModel = fixture.viewModel()

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "lifecycle", text: Fixture.lifecycleReady, date: 30)],
            agentInboxId: Fixture.agentInboxId
        )

        #expect(viewModel.state == nil)
        #expect(viewModel.docs.isEmpty)
        #expect(viewModel.controlLifecycle?.status == .ready)
        #expect(fixture.defaults.data(
            forKey: DocExperienceViewModel.storageKey("snapshot", accountIdentifier: "registering")
        ) == nil)
    }

    @Test("binding release removes the live disposition")
    func bindingReleaseRemovesLiveDisposition() throws {
        let fixture = try Fixture()
        let viewModel = fixture.viewModel()

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "live", text: Fixture.bindingLive, date: 40)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(viewModel.controlBinding(for: "tahoe-trip")?.status == .live)

        viewModel.ingestAggregatedMessages(
            [fixture.message(id: "released", text: Fixture.bindingReleased, date: 41)],
            agentInboxId: Fixture.agentInboxId
        )

        #expect(viewModel.controlBinding(for: "tahoe-trip")?.status == .released)
    }

    @Test("control persistence adopts, relaunches, and resets for a replacement agent")
    func controlPersistenceLifecycle() throws {
        let fixture = try Fixture()
        let firstLaunch = fixture.viewModel()
        let provisionalControlKey = DocExperienceViewModel.storageKey(
            "control",
            accountIdentifier: "registering"
        )
        let provisionalEditorialKey = DocExperienceViewModel.storageKey(
            "snapshot",
            accountIdentifier: "registering"
        )
        let editorialBytes = Data("editorial-snapshot".utf8)
        fixture.defaults.set(editorialBytes, forKey: provisionalEditorialKey)

        firstLaunch.ingestAggregatedMessages(
            [fixture.message(id: "first", text: Fixture.lifecycleReady, date: 50)],
            agentInboxId: Fixture.agentInboxId
        )
        #expect(fixture.defaults.data(forKey: provisionalControlKey) != nil)
        #expect(fixture.defaults.data(forKey: provisionalEditorialKey) == editorialBytes)

        firstLaunch.adoptAuthorizedStorage(inboxId: "owner-inbox")
        let authorizedControlKey = DocExperienceViewModel.storageKey(
            "control",
            accountIdentifier: "owner-inbox"
        )
        let authorizedEditorialKey = DocExperienceViewModel.storageKey(
            "snapshot",
            accountIdentifier: "owner-inbox"
        )
        #expect(fixture.defaults.data(forKey: provisionalControlKey) == nil)
        #expect(fixture.defaults.data(forKey: authorizedControlKey) != nil)

        let relaunched = fixture.viewModel()
        relaunched.adoptAuthorizedStorage(inboxId: "owner-inbox")
        #expect(relaunched.controlLifecycle?.status == .ready)

        relaunched.ingestAggregatedMessages(
            [fixture.message(
                id: "replacement",
                text: Fixture.replacementLifecycle,
                date: 51,
                senderInboxId: "replacement-agent"
            )],
            agentInboxId: "replacement-agent"
        )

        #expect(relaunched.controlSnapshot?.instanceId == Fixture.replacementInstanceId)
        #expect(fixture.defaults.data(forKey: authorizedEditorialKey) == editorialBytes)
    }

    private struct Fixture {
        static let agentInboxId: String = "doc-agent"
        static let instanceId: String = "F47AC10B-58CC-4372-A567-0E02B2C3D479"
        static let replacementInstanceId: String = "550E8400-E29B-41D4-A716-446655440000"
        static let epoch: String = "7D9E6679-7425-40DE-944B-E07FC1F90AE7"

        static let lifecycleReady: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":1,"at":1787720400,"key":"lifecycle","kind":"lifecycle","lifecycle":{"status":"ready","conversationId":"primary","failureCode":null}}"#
        static let replacementLifecycle: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"550E8400-E29B-41D4-A716-446655440000","epoch":"53A5C46C-31C1-409E-B277-9C84AFA23C91","seq":1,"at":1787720500,"key":"lifecycle","kind":"lifecycle","lifecycle":{"status":"ready","conversationId":"replacement-primary","failureCode":null}}"#
        static let legacyVerificationItem: String = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"523e4567-e89b-42d3-a456-426614174004","register":"waiting","kind":"verify_number","headline":"Verify your phone number","context":"Send the prefilled message.","code":"ABCD-EFGH-2345","lineNumber":"+16283095734","smsBody":"VERIFY ABCD-EFGH-2345","docId":null,"createdAt":1787720399}}"#
        static let verificationPending: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":10,"at":1787720400,"key":"verification:challenge","kind":"verification","verification":{"status":"pending","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":null,"code":"ABCD-EFGH-2345","smsBody":"VERIFY ABCD-EFGH-2345","expiresAt":1787724000,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        static let verificationVerified: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":11,"at":1787720500,"key":"verification:owner:+14155550123","kind":"verification","verification":{"status":"verified","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":"+14155550123","code":null,"smsBody":null,"expiresAt":1787724000,"verifiedAt":1787720500,"releasedAt":null,"clearsKey":"verification:challenge"}}"#
        static let verificationRenewed: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":12,"at":1787720600,"key":"verification:challenge","kind":"verification","verification":{"status":"pending","challengeId":"53A5C46C-31C1-409E-B277-9C84AFA23C91","lineNumber":"+16283095734","ownerNumber":null,"code":"WXYZ-EFGH-2345","smsBody":"VERIFY WXYZ-EFGH-2345","expiresAt":1787725000,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        static let verificationRequestSent: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":13,"at":1787720610,"key":"verification:request","kind":"verification","verification":{"status":"sent","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":"+14155550123","code":null,"smsBody":null,"expiresAt":1787724210,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        static let verificationSubmitFailed: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":14,"at":1787720620,"key":"verification:request","kind":"verification","verification":{"status":"attempt_failed","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":"+14155550123","code":null,"smsBody":null,"expiresAt":1787724210,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        static let verificationRequestFailed: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":15,"at":1787720630,"key":"verification:request","kind":"verification","verification":{"status":"send_failed","challengeId":null,"lineNumber":"+16283095734","ownerNumber":"+14155550123","code":null,"smsBody":null,"expiresAt":0,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        static let verificationOutboundVerified: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":16,"at":1787720640,"key":"verification:owner:+14155550123","kind":"verification","verification":{"status":"verified","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":"+14155550123","code":null,"smsBody":null,"expiresAt":1787724210,"verifiedAt":1787720640,"releasedAt":null,"clearsKey":"verification:request"}}"#
        static let googlePending: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":20,"at":1787720400,"key":"google:registering","kind":"google_docs","googleDocs":{"ownerInboxId":"registering","requestConversationId":null,"supersedesKey":null,"gate":{"status":"pending","requestId":"request-1","updatedAt":1787720400},"connection":{"status":"unknown","providerId":null,"updatedAt":1787720400}}}"#
        static let googleGranted: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":21,"at":1787720500,"key":"google:registering","kind":"google_docs","googleDocs":{"ownerInboxId":"registering","requestConversationId":null,"supersedesKey":null,"gate":{"status":"approved","requestId":"request-1","updatedAt":1787720500},"connection":{"status":"granted","providerId":"composio.googledocs","updatedAt":1787720500}}}"#
        static let googleRevoked: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":22,"at":1787720600,"key":"google:registering","kind":"google_docs","googleDocs":{"ownerInboxId":"registering","requestConversationId":null,"supersedesKey":null,"gate":{"status":"approved","requestId":"request-1","updatedAt":1787720500},"connection":{"status":"revoked","providerId":"composio.googledocs","updatedAt":1787720600}}}"#
        static let bindingLive: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":30,"at":1787720400,"key":"binding:thread:+16283095734:thread-1","kind":"binding","binding":{"status":"live","lineNumber":"+16283095734","threadId":"thread-1","conversationType":"group","groupName":"Tahoe","docId":"tahoe-trip","intentAt":1787720300,"boundAt":1787720400,"releasedAt":null,"supersedesKey":null}}"#
        static let bindingReleased: String = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":31,"at":1787720600,"key":"binding:thread:+16283095734:thread-1","kind":"binding","binding":{"status":"released","lineNumber":"+16283095734","threadId":"thread-1","conversationType":"group","groupName":"Tahoe","docId":"tahoe-trip","intentAt":1787720300,"boundAt":1787720400,"releasedAt":1787720600,"supersedesKey":null}}"#

        let suiteName: String
        let defaults: UserDefaults
        let session: MockInboxesService
        let agent: ConversationMember

        init(
            hasCompletedWelcome: Bool = false,
            hasCompletedFirstRun: Bool = false
        ) throws {
            suiteName = "DocControlViewModelTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            session = MockInboxesService()
            defaults.set(
                hasCompletedWelcome,
                forKey: "doc.v1.registering.welcome"
            )
            defaults.set(
                hasCompletedFirstRun,
                forKey: "doc.v1.registering.firstRun"
            )
            agent = ConversationMember(
                profile: .mock(inboxId: Self.agentInboxId, name: "Doc"),
                role: .member,
                isCurrentUser: false,
                isAgent: true
            )
        }

        @MainActor
        func viewModel() -> DocExperienceViewModel {
            DocExperienceViewModel(
                session: session,
                coreActions: NoOpCoreActions(),
                defaults: defaults
            )
        }

        func message(
            id: String,
            text: String,
            date: TimeInterval,
            senderInboxId: String = Self.agentInboxId
        ) -> AnyMessage {
            let sender = senderInboxId == Self.agentInboxId ? agent : ConversationMember(
                profile: .mock(inboxId: senderInboxId, name: "Doc"),
                role: .member,
                isCurrentUser: false,
                isAgent: true
            )
            return .message(
                Message(
                    id: id,
                    sender: sender,
                    source: .incoming,
                    status: .published,
                    content: .text(text),
                    date: Date(timeIntervalSince1970: date),
                    reactions: []
                ),
                .existing
            )
        }
    }
}
