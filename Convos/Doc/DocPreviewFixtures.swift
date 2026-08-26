import ConvosCore
import Foundation

extension DocExperienceViewModel {
    static var previewItems: [DocWaitingItem] {
        let now = Date()
        return [
            DocWaitingItem(
                id: "question-dates",
                kind: .question,
                headline: "Which weekend works for everyone?",
                context: "Tahoe Trip needs a date before Doc can update the plan.",
                chips: ["Dec 14", "Dec 21"],
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
                headline: "Keep Tahoe updated automatically",
                context: "Add Doc's number to the group.",
                docId: "tahoe-trip",
                createdAt: now
            ),
            DocWaitingItem(
                id: "ask-catchup",
                register: .ask,
                kind: .catchup,
                headline: "Catch Doc up",
                context: "Send recent screenshots from the group.",
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
        return DocState(line: previewNumber, docs: [
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
                    number: previewNumber,
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
                binding: DocBinding(state: .none, number: previewNumber),
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

    static let previewNumber: String = "+16285550123"
}
