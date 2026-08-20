import ConvosComposer
import Foundation
import Testing

@Suite("Agent composer curation")
struct ComposerAttachmentCurationTests {
    @Test("connections appears in the agent menu when enabled and nowhere when disabled")
    func connectionsFollowsTheSingleGate() {
        #expect(ComposerAttachmentAction.agentMenu(connectionsEnabled: true).contains(.connections))
        #expect(!ComposerAttachmentAction.agentMenu(connectionsEnabled: false).contains(.connections))
        #expect(!ComposerAttachmentAction.standard.contains(.connections))
    }

    @Test("agent menu keeps its curated order")
    func agentListOrdering() {
        #expect(ComposerAttachmentAction.agentMenu(connectionsEnabled: true) == [.photos, .camera, .files, .voiceNote, .connections])
        #expect(ComposerAttachmentAction.agentMenu(connectionsEnabled: false) == [.photos, .camera, .files, .voiceNote])
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

    @Test("menu rows keep the outline set")
    func outlineIconsPinned() {
        #expect(ComposerAttachmentAction.connections.iconSystemName == "powerplug")
        #expect(ComposerAttachmentAction.photos.iconSystemName == "photo")
        #expect(ComposerAttachmentAction.files.iconSystemName == "document")
    }
}
