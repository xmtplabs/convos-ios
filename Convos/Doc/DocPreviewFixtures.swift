import ConvosCore
import Foundation

extension DocExperienceViewModel {
    static var previewVerificationSnapshot: DocControlSnapshot {
        DocControlSnapshot(event: DocControlEvent(
            instanceId: "F47AC10B-58CC-4372-A567-0E02B2C3D479",
            epoch: "7D9E6679-7425-40DE-944B-E07FC1F90AE7",
            sequence: 1,
            occurredAt: 1_787_720_400,
            key: DocControlMessage.verificationChallengeKey,
            payload: .verification(DocControlVerification(
                status: .pending,
                challengeId: "A8098C1A-F86E-11DA-BD1A-00112444BE1E",
                lineNumber: DocPreviewConfiguration.contributionLine,
                ownerNumber: nil,
                code: "ABCD-2345-WXYZ",
                smsBody: "VERIFY ABCD-2345-WXYZ",
                expiresAt: 1_787_724_000,
                verifiedAt: nil,
                releasedAt: nil,
                clearsKey: nil
            ))
        ))
    }

    static var previewVerificationSentSnapshot: DocControlSnapshot {
        var snapshot = previewVerificationSnapshot
        _ = snapshot.apply(previewOutboundVerification(status: .sent))
        return snapshot
    }

    static var previewVerificationFallbackSnapshot: DocControlSnapshot {
        var snapshot = previewVerificationSnapshot
        _ = snapshot.apply(previewOutboundVerification(status: .sendFailed))
        return snapshot
    }

    private static func previewOutboundVerification(
        status: DocControlVerification.Status
    ) -> DocControlEvent {
        DocControlEvent(
            instanceId: "F47AC10B-58CC-4372-A567-0E02B2C3D479",
            epoch: "7D9E6679-7425-40DE-944B-E07FC1F90AE7",
            sequence: 2,
            occurredAt: 1_787_720_500,
            key: DocControlMessage.verificationRequestKey,
            payload: .verification(DocControlVerification(
                status: status,
                challengeId: status == .sendFailed ? nil : "B8098C1A-F86E-11DA-BD1A-00112444BE1E",
                lineNumber: DocPreviewConfiguration.contributionLine,
                ownerNumber: "+14155550123",
                code: nil,
                smsBody: nil,
                expiresAt: status == .sendFailed ? 0 : 1_787_724_100,
                verifiedAt: nil,
                releasedAt: nil,
                clearsKey: nil
            ))
        )
    }

    static var previewItems: [DocWaitingItem] {
        let now = Date()
        return [
            DocWaitingItem(
                id: "verify-number",
                kind: .verifyNumber,
                headline: "Verify your number",
                context: "Text this code from the phone you use with Doc.",
                code: "ABCD-2345-WXYZ",
                lineNumber: "+16283095734",
                smsBody: "VERIFY ABCD-2345-WXYZ",
                createdAt: now
            ),
            DocWaitingItem(
                id: "connect-tahoe",
                kind: .question,
                headline: "Is “Tahoe Weekend” your Tahoe Trip group?",
                context: "If you connect it, new texts from Tahoe Weekend will update this doc.",
                chips: ["Yes, bind it", "No"],
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-4 * 60)
            ),
            DocWaitingItem(
                id: "unknown-sender",
                kind: .unknownContributor,
                headline: "Who sent the cabin address?",
                context: "Name the person so Doc can credit the update.",
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-8 * 60)
            ),
        ]
    }

    static var previewRegisterItems: [DocWaitingItem] {
        let now = Date()
        return [
            DocWaitingItem(
                id: "waiting-preview",
                kind: .question,
                headline: "Which weekend works?",
                context: "Pick a date for the Tahoe plan.",
                chips: ["Dec 14", "Dec 21"],
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-60)
            ),
            DocWaitingItem(
                id: "draft-preview",
                register: .draft,
                kind: .structure,
                headline: "Drafted a Decisions section",
                context: "Turns the date choices into a clear section.",
                draft: DocDraft(
                    text: "## Decisions\n\n- Tahoe weekend: December 14\n- Cabin: North Shore",
                    anchor: "Plan"
                ),
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-2 * 60)
            ),
            DocWaitingItem(
                id: "ask-preview",
                register: .ask,
                kind: .staleCheck,
                headline: "Is Tahoe still active?",
                context: "The group has been quiet for two weeks.",
                chips: ["Keep active", "Pause", "Archive"],
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-3 * 60)
            ),
        ]
    }

    static var previewAskItems: [DocWaitingItem] {
        let now = Date()
        return [
            DocWaitingItem(
                id: "ask-bind",
                register: .ask,
                kind: .bindGroup,
                headline: "Connect Tahoe Trip to a group",
                context: "New texts from the group will update this doc.",
                docId: "tahoe-trip",
                createdAt: now
            ),
            DocWaitingItem(
                id: "ask-catchup",
                register: .ask,
                kind: .catchup,
                headline: "Want me to catch up on Tahoe Weekend?",
                context: "I only see texts sent after @doc joined. Add earlier screenshots for the full context.",
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-60)
            ),
            DocWaitingItem(
                id: "ask-names",
                register: .ask,
                kind: .nameContributors,
                headline: "Name two contributors",
                context: "Doc only has their phone numbers.",
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-2 * 60)
            ),
            DocWaitingItem(
                id: "ask-stale",
                register: .ask,
                kind: .staleCheck,
                headline: "Is Tahoe still active?",
                context: "There have been no recent updates.",
                chips: ["Keep active", "Pause", "Archive"],
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-3 * 60)
            ),
        ]
    }

    static var previewState: DocState {
        let now = Date()
        return DocState(line: DocPreviewConfiguration.contributionLine, docs: [
            DocStatus(
                id: "tahoe-trip",
                name: "Tahoe Trip",
                url: "https://docs.google.com/document/d/example-tahoe",
                updatedAt: now.addingTimeInterval(-12 * 60),
                lastChange: DocLastChange(
                    who: "Sara",
                    what: "added flight times",
                    at: now.addingTimeInterval(-12 * 60)
                ),
                binding: DocBinding(
                    state: .live,
                    number: DocPreviewConfiguration.contributionLine,
                    group: "Tahoe Weekend"
                ),
                dates: "Dec 12–15",
                people: 7
            ),
            DocStatus(
                id: "house-projects",
                name: "House Projects",
                url: "https://docs.google.com/document/d/example-house",
                updatedAt: now.addingTimeInterval(-3 * 60 * 60),
                lastChange: DocLastChange(
                    who: "Noah",
                    what: "checked off paint samples",
                    at: now.addingTimeInterval(-3 * 60 * 60)
                ),
                binding: DocBinding(state: .none, number: DocPreviewConfiguration.contributionLine),
                people: 4
            ),
        ])
    }

    static var previewContents: [DocContent] {
        let now = Date()
        return [
            DocContent(
                docId: "tahoe-trip",
                markdown: """
                # Tahoe Trip

                ## Plan

                Sara lands Friday at 4:30 PM. Meet at the cabin before dinner.

                ## Bring

                - Snow boots
                - Warm layers
                - Board games

                ## Open questions

                Confirm whether everyone prefers December 14 or December 21.
                """,
                changes: [
                    DocLastChange(
                        who: "Sara",
                        what: "added flight times",
                        at: now.addingTimeInterval(-12 * 60)
                    ),
                    DocLastChange(
                        who: "Noah",
                        what: "added the cabin address",
                        at: now.addingTimeInterval(-48 * 60)
                    ),
                    DocLastChange(
                        who: "Mina",
                        what: "started a packing list",
                        at: now.addingTimeInterval(-3 * 60 * 60)
                    ),
                ],
                updatedAt: now.addingTimeInterval(-12 * 60)
            ),
        ]
    }

    static var previewConnectingSnapshot: DocControlSnapshot {
        previewBindingSnapshot(
            status: .pending,
            groupName: nil,
            docId: "house-projects"
        )
    }

    static var previewConnectedNamedSnapshot: DocControlSnapshot {
        previewBindingSnapshot(
            status: .live,
            groupName: "Tahoe Weekend",
            docId: "tahoe-trip"
        )
    }

    static var previewConnectedUnnamedSnapshot: DocControlSnapshot {
        previewBindingSnapshot(
            status: .live,
            groupName: nil,
            docId: "tahoe-trip"
        )
    }

    static var previewEndedSnapshot: DocControlSnapshot {
        previewBindingSnapshot(
            status: .released,
            groupName: "Tahoe Weekend",
            docId: "tahoe-trip"
        )
    }

    static var previewUnmatchedGroupSnapshot: DocControlSnapshot {
        previewBindingSnapshot(
            status: .live,
            groupName: nil,
            docId: nil
        )
    }

    private static func previewBindingSnapshot(
        status: DocControlBinding.Status,
        groupName: String?,
        docId: String?
    ) -> DocControlSnapshot {
        let isPending = status == .pending
        let binding = DocControlBinding(
            status: status,
            lineNumber: DocPreviewConfiguration.contributionLine,
            threadId: isPending ? nil : "preview-thread",
            conversationType: isPending ? nil : .group,
            groupName: groupName,
            docId: docId,
            intentAt: 1_787_720_300,
            boundAt: isPending ? nil : 1_787_720_400,
            releasedAt: status == .released ? 1_787_720_600 : nil,
            supersedesKey: nil
        )
        return DocControlSnapshot(event: DocControlEvent(
            instanceId: "F47AC10B-58CC-4372-A567-0E02B2C3D479",
            epoch: "7D9E6679-7425-40DE-944B-E07FC1F90AE7",
            sequence: 2,
            occurredAt: 1_787_720_400,
            key: docId.map { "binding:doc:\($0)" } ?? "binding:thread:preview",
            payload: .binding(binding)
        ))
    }
}
