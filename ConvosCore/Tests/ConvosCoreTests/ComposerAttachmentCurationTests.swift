import ConvosComposer
import Foundation
import Testing

@Suite("Agent composer curation")
struct ComposerAttachmentCurationTests {
    @Test("quick row is a subset of the menu in both flag states")
    func quickRowIsCurationOfMenu() {
        for connectionsEnabled in [true, false] {
            let menu = ComposerAttachmentAction.agentMenu(connectionsEnabled: connectionsEnabled)
            let quickRow = ComposerAttachmentAction.agentQuickRow(connectionsEnabled: connectionsEnabled)
            for action in quickRow {
                #expect(menu.contains(action), "quick row offers \(action) the menu withholds (connectionsEnabled: \(connectionsEnabled))")
            }
        }
    }

    @Test("connections appears in both lists when enabled and in neither when disabled")
    func connectionsFollowsTheSingleGate() {
        #expect(ComposerAttachmentAction.agentMenu(connectionsEnabled: true).contains(.connections))
        #expect(ComposerAttachmentAction.agentQuickRow(connectionsEnabled: true).contains(.connections))
        #expect(!ComposerAttachmentAction.agentMenu(connectionsEnabled: false).contains(.connections))
        #expect(!ComposerAttachmentAction.agentQuickRow(connectionsEnabled: false).contains(.connections))
    }

    @Test("agent lists keep their curated order")
    func agentListOrdering() {
        #expect(ComposerAttachmentAction.agentMenu(connectionsEnabled: true) == [.photos, .camera, .files, .voiceNote, .connections])
        #expect(ComposerAttachmentAction.agentMenu(connectionsEnabled: false) == [.photos, .camera, .files, .voiceNote])
        #expect(ComposerAttachmentAction.agentQuickRow(connectionsEnabled: true) == [.photos, .files, .connections])
        #expect(ComposerAttachmentAction.agentQuickRow(connectionsEnabled: false) == [.photos, .files])
    }

    @Test("the group composer's standard menu is untouched")
    func standardMenuUnchanged() {
        #expect(ComposerAttachmentAction.standard == [.photos, .camera, .files, .voiceNote])
        #expect(!ComposerAttachmentAction.standard.contains(.connections))
    }
}

@Suite("Composer attachment dispatch")
struct ComposerAttachmentDispatchTests {
    @Test("connections routes to the host callback, never to a picker")
    func connectionsRoutesToHost() {
        #expect(ComposerAttachmentAction.connections.dispatch == .hostConnections)
    }

    @Test("only connections routes to the host callback")
    func onlyConnectionsRoutesToHost() {
        for action in ComposerAttachmentAction.allCases where action != .connections {
            #expect(action.dispatch != .hostConnections, "\(action) must not route to the host connections callback")
        }
    }

    @Test("picker actions keep their picker routing")
    func pickerRoutingPinned() {
        #expect(ComposerAttachmentAction.photos.dispatch == .photoPicker)
        #expect(ComposerAttachmentAction.camera.dispatch == .cameraPicker)
        #expect(ComposerAttachmentAction.files.dispatch == .filePicker)
        #expect(ComposerAttachmentAction.voiceNote.dispatch == .voiceMemo)
        #expect(ComposerAttachmentAction.debugInjector.dispatch == .debugInjector)
    }

    @Test("filled icon mapping covers every quick-row case")
    func filledIconsCoverQuickRow() {
        for action in ComposerAttachmentAction.agentQuickRow(connectionsEnabled: true) {
            #expect(!action.filledIconSystemName.isEmpty)
        }
        #expect(ComposerAttachmentAction.photos.filledIconSystemName == "photo.fill")
        #expect(ComposerAttachmentAction.files.filledIconSystemName == "document.fill")
        #expect(ComposerAttachmentAction.connections.filledIconSystemName == "powerplug.fill")
    }

    @Test("menu rows keep the outline set")
    func outlineIconsPinned() {
        #expect(ComposerAttachmentAction.connections.iconSystemName == "powerplug")
    }
}

@Suite("Agent quick row visibility")
struct AgentComposerQuickRowVisibilityTests {
    @Test("visible only in the default state")
    func defaultStateShowsRow() {
        #expect(AgentComposerQuickRow.isVisible(isMessageFieldFocused: false, messageText: ""))
    }

    @Test("hidden while the field is focused")
    func focusHidesRow() {
        #expect(!AgentComposerQuickRow.isVisible(isMessageFieldFocused: true, messageText: ""))
    }

    @Test("hidden while text is drafted")
    func draftedTextHidesRow() {
        #expect(!AgentComposerQuickRow.isVisible(isMessageFieldFocused: false, messageText: "hello"))
        #expect(!AgentComposerQuickRow.isVisible(isMessageFieldFocused: true, messageText: "hello"))
    }
}
