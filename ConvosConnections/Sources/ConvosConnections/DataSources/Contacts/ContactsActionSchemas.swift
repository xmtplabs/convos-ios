import Foundation

/// Static `ActionSchema` values published by `ContactsDataSink`.
public enum ContactsActionSchemas {
    public static let createContact: ActionSchema = ActionSchema(
        kind: .contacts,
        actionName: "create_contact",
        capability: .writeCreate,
        summary: "Create a new contact in the user's address book.",
        inputs: [
            ActionParameter(name: "givenName", type: .string, description: "Given (first) name.", isRequired: false),
            ActionParameter(name: "familyName", type: .string, description: "Family (last) name.", isRequired: false),
            ActionParameter(name: "organization", type: .string, description: "Organization name.", isRequired: false),
            ActionParameter(name: "phone", type: .string, description: "Primary phone number (E.164 preferred).", isRequired: false),
            ActionParameter(name: "email", type: .string, description: "Primary email address.", isRequired: false),
            ActionParameter(name: "note", type: .string, description: "Free-form note attached to the contact.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "contactId", type: .string, description: "Newly-created contact identifier.", isRequired: true),
        ]
    )

    public static let updateContact: ActionSchema = ActionSchema(
        kind: .contacts,
        actionName: "update_contact",
        capability: .writeUpdate,
        summary: "Update an existing contact.",
        inputs: [
            ActionParameter(name: "contactId", type: .string, description: "Identifier of the contact to update.", isRequired: true),
            ActionParameter(name: "givenName", type: .string, description: "New given name.", isRequired: false),
            ActionParameter(name: "familyName", type: .string, description: "New family name.", isRequired: false),
            ActionParameter(name: "organization", type: .string, description: "New organization.", isRequired: false),
            ActionParameter(name: "phone", type: .string, description: "Replace primary phone number.", isRequired: false),
            ActionParameter(name: "email", type: .string, description: "Replace primary email address.", isRequired: false),
            ActionParameter(name: "note", type: .string, description: "Replace note.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "contactId", type: .string, description: "Updated contact identifier.", isRequired: true),
        ]
    )

    public static let deleteContact: ActionSchema = ActionSchema(
        kind: .contacts,
        actionName: "delete_contact",
        capability: .writeDelete,
        summary: "Delete a contact from the user's address book.",
        inputs: [
            ActionParameter(name: "contactId", type: .string, description: "Identifier of the contact to delete.", isRequired: true),
        ],
        outputs: []
    )

    public static let all: [ActionSchema] = [createContact, updateContact, deleteContact]
}
