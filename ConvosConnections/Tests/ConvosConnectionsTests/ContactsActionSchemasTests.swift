@testable import ConvosConnections
import Testing

@Suite("Contacts action schemas")
struct ContactsActionSchemasTests {
    @Test("publishes three actions")
    func publishesThreeActions() {
        let schemas = ContactsActionSchemas.all
        #expect(schemas.count == 3)
        let names = Set(schemas.map(\.actionName))
        #expect(names == ["create_contact", "update_contact", "delete_contact"])
    }

    @Test("each action has the right capability")
    func capabilities() {
        #expect(ContactsActionSchemas.createContact.capability == .writeCreate)
        #expect(ContactsActionSchemas.updateContact.capability == .writeUpdate)
        #expect(ContactsActionSchemas.deleteContact.capability == .writeDelete)
    }

    @Test("update and delete require contactId")
    func identifiersAreRequired() {
        let updateRequired = ContactsActionSchemas.updateContact.inputs.first { $0.name == "contactId" }
        let deleteRequired = ContactsActionSchemas.deleteContact.inputs.first { $0.name == "contactId" }
        #expect(updateRequired?.isRequired == true)
        #expect(deleteRequired?.isRequired == true)
    }

    @Test("ContactsDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = ContactsDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == ContactsActionSchemas.all)
    }
}
